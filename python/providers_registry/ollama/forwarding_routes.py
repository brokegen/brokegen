import logging
from datetime import datetime, timezone
from typing import AsyncIterator, Awaitable, AsyncGenerator

import httpx
import orjson
import sqlalchemy
import starlette
import starlette.responses
from fastapi import FastAPI, APIRouter, Depends, HTTPException
from starlette.requests import Request

from _util.json import safe_get, JSONDict, safe_get_arrayed
from _util.json_streaming import JSONStreamingResponse, emit_keepalive_chunks_with_log
from _util.status import ServerStatusHolder
from audit.http import AuditDB, get_db as get_audit_db
from client.database import HistoryDB, get_db as get_history_db
from client_ollama.forward import forward_request_nolog, forward_request
from inference.continuation import AutonamingOptions
from inference.iterators import consolidate_and_call, tee_to_console_output, decode_from_bytes, stream_str_to_json, \
    dump_to_bytes
from providers.inference_models.orm import InferenceEventOrm
from providers.registry import ProviderRegistry, InferenceOptions
from providers_registry.ollama.api_chat.inject_rag import do_proxy_chat_rag
from providers_registry.ollama.api_chat.logging import OllamaRequestContentJSON, OllamaResponseContentJSON, \
    finalize_inference_job, ollama_response_consolidator, ollama_log_indexer
from providers_registry.ollama.api_generate import do_generate_raw_templated
from providers_registry.ollama.chat_routes import lookup_model_offline
from providers_registry.ollama.json import keepalive_wrapper
from providers_registry.ollama.models.list import do_api_tags, do_api_show
from providers_registry.ollama.registry import ExternalOllamaFactory
from retrieval.faiss.retrieval import RetrievalLabel

logger = logging.getLogger(__name__)


def install_forwards(app: FastAPI, force_ollama_rag: bool):
    ollama_forwarder = APIRouter()

    @ollama_forwarder.post("/ollama-proxy/api/generate")
    async def proxy_generate(
            request: Request,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ):
        request_content: OllamaRequestContentJSON = orjson.loads(await request.body())

        async def real_response_maker() -> AsyncIterator[JSONDict]:
            generate_response: starlette.responses.StreamingResponse = \
                await do_generate_raw_templated(
                    request_content=request_content,
                    history_db=history_db,
                    audit_db=audit_db,
                    inference_reason="/api/generate intercept",
                )

            iter0: AsyncIterator[bytes] = generate_response.body_iterator
            iter1: AsyncIterator[str] = decode_from_bytes(iter0)
            iter2: AsyncIterator[JSONDict] = stream_str_to_json(iter1)

            return iter2

        async def nonblocking_response_maker(
                real_response_maker: Awaitable[AsyncIterator[JSONDict]],
        ) -> AsyncIterator[JSONDict]:
            async for item in (await real_response_maker):
                yield item

        async def do_keepalive(
                primordial: AsyncIterator[JSONDict],
        ) -> AsyncGenerator[JSONDict, None]:
            async for chunk in emit_keepalive_chunks_with_log(primordial, 3.0, None, logger.debug):
                if chunk is None:
                    yield {
                        "model": safe_get(request_content, "model"),
                        "created_at": datetime.now(tz=timezone.utc).isoformat() + "Z",
                        "done": False,
                        "response": "",
                    }

                else:
                    yield chunk

                if await request.is_disconnected():
                    logger.fatal(f"Detected client disconnection! Ignoring, because we want inference to continue.")

        async def add_newlines(primordial: AsyncIterator[bytes]) -> AsyncIterator[bytes]:
            async for chunk in primordial:
                yield chunk + b'\n'

        awaitable: Awaitable[AsyncIterator[JSONDict]] = real_response_maker()
        iter0: AsyncIterator[JSONDict] = nonblocking_response_maker(awaitable)
        iter1: AsyncIterator[JSONDict] = do_keepalive(iter0)
        iter2: AsyncIterator[bytes] = dump_to_bytes(iter1)
        iter3: AsyncIterator[bytes] = add_newlines(iter2)

        return JSONStreamingResponse(
            content=iter3,
            status_code=200,
        )

    @ollama_forwarder.post("/ollama-proxy/api/chat")
    async def proxy_chat_rag(
            request: Request,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        # Trigger Ollama providers, if needed
        # TODO: Refactor this into shared code
        ollama_providers = [provider for (label, provider) in registry.by_label.items() if label.type == "ollama"]
        if not ollama_providers:
            await ExternalOllamaFactory().discover(None, registry)

        request_content_bytes: bytes = await request.body()
        request_content_json: OllamaRequestContentJSON = orjson.loads(request_content_bytes)

        inference_model_human_id = safe_get(request_content_json, "model")
        status_holder = ServerStatusHolder(f"Received /api/chat request for {inference_model_human_id}, processing")

        try:
            inference_model, _ = await lookup_model_offline(
                inference_model_human_id,
                history_db,
            )

            if safe_get(request_content_json, 'options', 'temperature') is not None:
                logger.debug(
                    f"Intentionally disabling Ollama client request for {request_content_json['options']['temperature']=}")
                del request_content_json['options']['temperature']

            last_message_images: JSONDict | None = safe_get_arrayed(request_content_json, 'messages', -1, 'images')
            if last_message_images:
                logger.info("Can't convert multimodal request, disabling RAG")
                return await keepalive_wrapper(
                    inference_model_human_id,
                    forward_request(request, audit_db),
                    status_holder,
                    request,
                )

            else:
                async def get_response():
                    prompt_with_templating, ollama_response = await do_proxy_chat_rag(
                        request,
                        request_content_json,
                        inference_model=inference_model,
                        inference_options=InferenceOptions(),
                        autonaming_options=AutonamingOptions(),
                        retrieval_label=RetrievalLabel(
                            retrieval_policy="simple" if force_ollama_rag else "skip",
                        ),
                        history_db=history_db,
                        audit_db=audit_db,
                        capture_chat_messages=True,
                        status_holder=status_holder,
                    )

                    async def record_inference_event(
                            consolidated_response: OllamaResponseContentJSON,
                    ) -> None:
                        nonlocal inference_model
                        inference_model = history_db.merge(inference_model)

                        inference_event = InferenceEventOrm(
                            model_record_id=inference_model.id,
                            prompt_with_templating=prompt_with_templating,
                            reason="/api/chat intercept",
                            response_created_at=datetime.now(tz=timezone.utc),
                            response_error="[haven't received/finalized response info yet]",
                        )
                        finalize_inference_job(inference_event, consolidated_response)

                        try:
                            history_db.add(inference_event)
                            history_db.commit()
                        except sqlalchemy.exc.SQLAlchemyError:
                            logger.exception(f"Failed to commit intercepted inference event for {inference_event}")
                            history_db.rollback()

                    if status_holder is not None:
                        status_holder.set(f"Running Ollama response")

                    iter1: AsyncIterator[JSONDict] = ollama_response._content_iterable
                    iter2: AsyncIterator[JSONDict] = tee_to_console_output(iter1, ollama_log_indexer)
                    iter3: AsyncIterator[JSONDict] = consolidate_and_call(
                        iter2, ollama_response_consolidator, {},
                        record_inference_event,
                    )

                    ollama_response._content_iterable = iter3
                    return ollama_response

                return await keepalive_wrapper(
                    inference_model_human_id,
                    get_response(),
                    status_holder,
                    request,
                )
        except HTTPException as e:
            return starlette.responses.JSONResponse(
                content={
                    "model": inference_model_human_id,
                    "message": {
                        "role": "assistant",
                        "content": str(e),
                    },
                    "done": True,
                },
                status_code=200,
            )

    # TODO: Using a router prefix breaks this, somehow
    @ollama_forwarder.head("/ollama-proxy/{ollama_head_path:path}")
    async def proxy_head(
            request: Request,
            ollama_head_path,
    ):
        try:
            return await forward_request_nolog(ollama_head_path, request)
        except httpx.ConnectError:
            return starlette.responses.Response(status_code=500)

    @ollama_forwarder.get("/ollama-proxy/{ollama_get_path:path}")
    @ollama_forwarder.post("/ollama-proxy/{ollama_post_path:path}")
    async def proxy_get_post(
            request: Request,
            ollama_get_path: str | None = None,
            ollama_post_path: str | None = None,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ):
        if ollama_get_path == "api/tags":
            return await do_api_tags(request, history_db, audit_db)

        if ollama_post_path == "api/show":
            request_content_json: dict = orjson.loads(await request.body())
            return await do_api_show(request_content_json['name'], history_db, audit_db)

        return await forward_request(request, audit_db)

    app.include_router(ollama_forwarder)
