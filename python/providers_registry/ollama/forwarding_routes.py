import functools
import logging
from datetime import datetime, timezone
from typing import AsyncIterator, Awaitable, AsyncGenerator

import fastapi
import httpx
import orjson
import sqlalchemy
import starlette.requests
import starlette.responses
from fastapi import FastAPI, APIRouter, Depends

from _util.json import safe_get, JSONDict, safe_get_arrayed, JSONArray
from _util.json_streaming import JSONStreamingResponse, emit_keepalive_chunks
from _util.status import ServerStatusHolder
from _util.typing import FoundationModelHumanID, PromptText, TemplatedPromptText
from audit.http import AuditDB, get_db as get_audit_db
from client.database import HistoryDB, get_db as get_history_db
from client.message import ChatMessageOrm
from client.sequence import ChatSequenceOrm
from client_ollama.forward import forward_request_nolog, forward_request
from inference.iterators import consolidate_and_call, tee_to_console_output, decode_from_bytes, stream_str_to_json, \
    dump_to_bytes
from inference.logging import construct_new_sequence_from, construct_assistant_message
from providers.foundation_models.orm import InferenceEventOrm, FoundationModelRecordOrm
from providers.registry import ProviderRegistry, InferenceOptions
from providers_registry.ollama.api_chat.inject_rag import do_proxy_chat_rag
from client_ollama.emulate_api_chat import do_capture_chat_messages
from providers_registry.ollama.api_chat.logging import OllamaRequestContentJSON, OllamaResponseContentJSON, \
    finalize_inference_job, ollama_response_consolidator, ollama_log_indexer
from providers_registry.ollama.api_generate import do_generate_raw_templated
from providers_registry.ollama.json import keepalive_wrapper
from providers_registry.ollama.models.list import do_api_tags, do_api_show
from providers_registry.ollama.models.lookup import lookup_model_offline
from providers_registry.ollama.registry import ExternalOllamaFactory
from retrieval.faiss.retrieval import RetrievalLabel

logger = logging.getLogger(__name__)


async def do_api_chat_textonly(
        request_content_json: OllamaRequestContentJSON,
        inference_model: FoundationModelRecordOrm,
        inference_options: InferenceOptions,
        retrieval_label: RetrievalLabel,
        status_holder: ServerStatusHolder,
        request: starlette.requests.Request,
        history_db: HistoryDB,
        audit_db: AuditDB,
):
    async def record_inference_result(
            consolidated_response: OllamaResponseContentJSON,
            captured_sequence: ChatSequenceOrm | None,
            prompt_with_templating: TemplatedPromptText,
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
            logger.exception(f"Failed to commit {inference_event=}")
            history_db.rollback()

        # And now, construct the ChatSequence (which references the InferenceEvent, actually)
        if captured_sequence is not None:
            try:
                response_message: ChatMessageOrm | None = construct_assistant_message(
                    maybe_response_seed=inference_options.seed_assistant_response or "",
                    assistant_response=ollama_log_indexer(consolidated_response),
                    created_at=inference_event.response_created_at,
                    history_db=history_db,
                )
                if not response_message:
                    return

                response_sequence: ChatSequenceOrm = await construct_new_sequence_from(
                    captured_sequence,
                    response_message.id,
                    inference_event,
                    history_db,
                )

                if not safe_get(consolidated_response, 'done'):
                    logger.debug(f"Generated ChatSequence#{response_sequence.id}, but response was marked not-done")

            except sqlalchemy.exc.SQLAlchemyError:
                logger.exception(f"Failed to create add-on ChatSequence from {consolidated_response}")
                history_db.rollback()

    # Assume that these are messages from a third-party client, and try to feed them into the history database.
    chat_messages: JSONArray | None = safe_get(request_content_json, 'messages')
    if not chat_messages:
        raise RuntimeError("No 'messages' provided in call to /api/chat")

    captured_sequence: ChatSequenceOrm | None
    requested_system_message: PromptText | None
    captured_sequence, requested_system_message = do_capture_chat_messages(chat_messages, history_db)

    prompt_with_templating, ollama_response = await do_proxy_chat_rag(
        request,
        request_content_json,
        inference_model=inference_model,
        inference_options=inference_options,
        retrieval_label=retrieval_label,
        history_db=history_db,
        audit_db=audit_db,
        status_holder=status_holder,
        requested_system_message=requested_system_message,
    )

    iter1: AsyncIterator[JSONDict] = ollama_response._content_iterable
    iter2: AsyncIterator[JSONDict] = tee_to_console_output(iter1, ollama_log_indexer)
    iter3: AsyncIterator[JSONDict] = consolidate_and_call(
        iter2, ollama_response_consolidator, {},
        functools.partial(
            record_inference_result,
            captured_sequence=captured_sequence,
            prompt_with_templating=prompt_with_templating,
        ),
    )

    ollama_response._content_iterable = iter3
    return ollama_response


async def do_api_chat(
        request: starlette.requests.Request,
        force_ollama_rag: bool,
        history_db: HistoryDB,
        audit_db: AuditDB,
        registry: ProviderRegistry,
):
    # Trigger Ollama providers, if needed
    # TODO: Refactor this into shared code
    ollama_providers = [provider for (label, provider) in registry.by_label.items() if label.type == "ollama"]
    if not ollama_providers:
        await ExternalOllamaFactory().discover(None, registry)

    request_content_bytes: bytes = await request.body()
    request_content_json: OllamaRequestContentJSON = orjson.loads(request_content_bytes)

    inference_model_human_id: FoundationModelHumanID = safe_get(request_content_json, "model")
    status_holder = ServerStatusHolder(f"Received /api/chat request for {inference_model_human_id}, processing")

    try:
        inference_model: FoundationModelRecordOrm
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
            )

        else:
            return await keepalive_wrapper(
                inference_model_human_id,
                do_api_chat_textonly(
                    request_content_json,
                    inference_model=inference_model,
                    inference_options=InferenceOptions(),
                    retrieval_label=RetrievalLabel(
                        retrieval_policy="simple" if force_ollama_rag else "skip",
                    ),
                    status_holder=status_holder,
                    request=request,
                    history_db=history_db,
                    audit_db=audit_db,
                ),
                status_holder,
            )

    except fastapi.HTTPException as e:
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


def install_forwards(app: FastAPI, force_ollama_rag: bool):
    ollama_forwarder = APIRouter()

    @ollama_forwarder.post("/api/generate")
    async def proxy_generate(
            request: starlette.requests.Request,
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
            async for chunk in emit_keepalive_chunks(primordial, 3.0, None):
                if chunk is None:
                    yield {
                        "model": safe_get(request_content, "model"),
                        "created_at": datetime.now(tz=timezone.utc).isoformat() + "Z",
                        "done": False,
                        "response": "",
                    }

                else:
                    yield chunk

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

    @ollama_forwarder.post("/api/chat")
    async def proxy_chat(
            request: starlette.requests.Request,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        return await do_api_chat(
            request,
            force_ollama_rag,
            history_db,
            audit_db,
            registry,
        )

    @ollama_forwarder.get("/{ollama_get_path:path}")
    @ollama_forwarder.post("/{ollama_post_path:path}")
    async def proxy_get_post(
            request: starlette.requests.Request,
            ollama_get_path: str | None = None,
            ollama_post_path: str | None = None,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ):
        if ollama_get_path == "api/tags":
            return await do_api_tags(request, history_db, audit_db)

        if ollama_post_path == "api/show":
            try:
                request_content_json: dict = orjson.loads(await request.body())
                return await do_api_show(request_content_json['name'], history_db, audit_db)
            except RuntimeError as e:
                logger.warning(f"/ollama-proxy/api/show failed, continuing with normal forward: {e}")

        return await forward_request(request, audit_db)

    if force_ollama_rag:
        app.include_router(ollama_forwarder, prefix="/ollama-proxy-rag")
    else:
        app.include_router(ollama_forwarder, prefix="/ollama-proxy")

    # TODO: Using a router prefix breaks this, somehow
    @app.head(
        "/ollama-proxy-rag/" if force_ollama_rag else "/ollama-proxy/"
    )
    async def proxy_head(
            request: starlette.requests.Request,
    ):
        try:
            return await forward_request_nolog("/", request)
        except (httpx.ConnectError, httpx.ConnectTimeout):
            return starlette.responses.Response(status_code=500)
