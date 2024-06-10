import logging

import orjson
from fastapi import FastAPI, Depends
from starlette.requests import Request

from audit.http import AuditDB, get_db as get_audit_db
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.orm import ProviderID, ProviderType, ProviderLabel
from providers.registry import ProviderRegistry, BaseProvider
from providers_ollama.forwarding import forward_request
from providers_ollama.model_routes import do_api_tags, do_api_show

logger = logging.getLogger(__name__)


async def emulate_api_tags(
        provider: BaseProvider,
):
    provider.stream

    upstream_request = _real_ollama_client.build_request(
        method=original_request.method,
        url="/api/tags",
        content=intercept.wrap_streaming_request(original_request.stream()),
        # https://github.com/encode/httpx/discussions/2959
        # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
        headers=[('Connection', 'close')],
        cookies=original_request.cookies,
    )

    async def on_done_fetching(response_content_json):
        provider = ProviderRegistry().by_label[ProviderLabel(type="ollama", id=str(_real_ollama_client.base_url))]
        list(build_models_from_api_tags(
            await provider.make_record(),
            cached_accessed_at,
            response_content_json,
            history_db=history_db,
        ))

    upstream_response = await _real_ollama_client.send(upstream_request)
    return await intercept.wrap_response(upstream_response, on_done_fetching)


def install_forwards(router_ish: FastAPI):
    @router_ish.get("/providers/{provider_type:str}/any/{ollama_get_path:path}")
    async def ollama_get(
            original_request: Request,
            provider_type: ProviderType,
            ollama_get_path: str | None = None,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        pass

    @router_ish.get("/providers/{provider_type:str}/{provider_id:path}/{ollama_get_path:path}")
    @router_ish.get("/providers/{provider_type:str}/{provider_id:path}/{ollama_post_path:path}")
    async def ollama_get_or_post(
            original_request: Request,
            provider_type: ProviderType,
            provider_id: ProviderID,
            ollama_get_path: str | None = None,
            ollama_post_path: str | None = None,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        label = ProviderLabel(type=provider_type, id=provider_id)
        provider = registry.by_label[label]

        if ollama_get_path == "api/tags":
            return await emulate_api_tags(provider)

        if ollama_post_path == "api/show":
            request_content_json: dict = orjson.loads(await original_request.body())
            return await do_api_show(request_content_json['name'], history_db, audit_db)

        return await forward_request(original_request, audit_db)
