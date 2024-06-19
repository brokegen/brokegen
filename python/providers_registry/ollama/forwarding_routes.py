import logging

import httpx
import orjson
import starlette
import starlette.responses
from fastapi import FastAPI, APIRouter, Depends
from starlette.requests import Request

from _util.json import safe_get, JSONDict, safe_get_arrayed
from _util.status import ServerStatusHolder
from audit.http import AuditDB, get_db as get_audit_db
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceReason
from providers.registry import ProviderRegistry
from providers_registry.ollama.api_chat.inject_rag import do_proxy_chat_rag
from providers_registry.ollama.chat_routes import do_proxy_generate
from providers_registry.ollama.forwarding import forward_request_nolog, forward_request
from providers_registry.ollama.json import keepalive_wrapper, OllamaRequestContentJSON
from providers_registry.ollama.model_routes import do_api_tags, do_api_show
from providers_registry.ollama.registry import ExternalOllamaFactory
from retrieval.faiss.retrieval import RetrievalLabel

logger = logging.getLogger(__name__)


def install_forwards(app: FastAPI, force_ollama_rag: bool):
    ollama_forwarder = APIRouter()

    @ollama_forwarder.post("/ollama-proxy/api/generate")
    async def proxy_generate(
            request: Request,
            inference_reason: InferenceReason = "prompt",
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ):
        inference_model_human_id = safe_get(orjson.loads(await request.body()), "model")
        status_holder = ServerStatusHolder(f"Received /api/generate request for {inference_model_human_id}, processing")

        return await keepalive_wrapper(
            inference_model_human_id,
            do_proxy_generate(request, inference_reason, history_db, audit_db),
            status_holder,
        )

    @ollama_forwarder.post("/ollama-proxy/api/chat")
    async def proxy_chat_rag(
            request: Request,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        inference_model_human_id = safe_get(orjson.loads(await request.body()), "model")
        status_holder = ServerStatusHolder(f"Received /api/chat request for {inference_model_human_id}, processing")

        # Check for Ollama providers
        # TODO: Refactor this into shared code
        ollama_providers = [provider for (label, provider) in registry.by_label.items() if label.type == "ollama"]
        if not ollama_providers:
            await ExternalOllamaFactory().discover(None, registry)

        retrieval_label = RetrievalLabel(
            retrieval_policy="simple" if force_ollama_rag else "skip",
        )

        request_content_bytes: bytes = await request.body()
        request_content_json: OllamaRequestContentJSON = orjson.loads(request_content_bytes)

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

        return await keepalive_wrapper(
            inference_model_human_id,
            do_proxy_chat_rag(
                request,
                request_content_json,
                retrieval_label,
                history_db,
                audit_db,
                capture_chat_response=True,
                status_holder=status_holder,
            ),
            status_holder,
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