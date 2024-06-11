import logging
from typing import AsyncIterable

import orjson
from fastapi import FastAPI, Depends, HTTPException
from starlette.requests import Request

from _util.json import JSONArray, JSONDict, safe_get
from audit.http import AuditDB, get_db as get_audit_db
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.orm import ProviderID, ProviderType, ProviderLabel
from providers.registry import ProviderRegistry, BaseProvider
from providers_ollama.forwarding import forward_request
from providers_ollama.model_routes import do_api_tags, do_api_show

logger = logging.getLogger(__name__)


async def emulate_api_tags(
        provider: BaseProvider,
) -> AsyncIterable[JSONDict]:
    async for model in provider.list_models():
        # If it's an Ollama-compatible record, just return that
        if safe_get(model.model_identifiers, 'name'):
            yield {
                "provider": model.provider_identifiers,
                **model.model_identifiers,
            }

        else:
            model_out = {
                "name": model.human_id,
                "details": model.model_identifiers,
                "provider": model.provider_identifiers,
            }
            yield model_out


def install_forwards(router_ish: FastAPI):
    @router_ish.get("/providers/any/any/{ollama_get_path:path}")
    async def ollama_get(
            original_request: Request,
            ollama_get_path: str,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        if ollama_get_path == "api/tags":
            collected_model_info = []
            for _, provider in ProviderRegistry().by_label.items():
                collected_model_info.extend(
                    [m async for m in emulate_api_tags(provider)]
                )

            return {"models": collected_model_info}

        raise HTTPException(501, "\"any\" provider_id not implemented")

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
            return {"models": [m async for m in emulate_api_tags(provider)]}

        if ollama_post_path == "api/show":
            request_content_json: dict = orjson.loads(await original_request.body())
            return await do_api_show(request_content_json['name'], history_db, audit_db)

        return await forward_request(original_request, audit_db)
