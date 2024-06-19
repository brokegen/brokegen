import hashlib
import logging
from typing import AsyncIterable

import orjson
from fastapi import FastAPI, Depends, HTTPException
from starlette.requests import Request

from _util.json import JSONDict
from audit.http import AuditDB, get_db as get_audit_db
from client.database import HistoryDB, get_db as get_history_db
from providers.orm import ProviderID, ProviderType, ProviderLabel
from providers.registry import ProviderRegistry, BaseProvider
from providers_registry.ollama.forwarding import forward_request
from providers_registry.ollama.model_routes import do_api_show

logger = logging.getLogger(__name__)


async def emulate_api_tags(
        label: ProviderLabel,
        provider: BaseProvider,
) -> AsyncIterable[JSONDict]:
    async for model in provider.list_models():
        def compute_hash() -> str:
            sha256_hasher = hashlib.sha256()
            sha256_hasher.update(model.provider_identifiers.encode())
            sha256_hasher.update(orjson.dumps(model.model_identifiers, option=orjson.OPT_SORT_KEYS))

            return sha256_hasher.hexdigest()

        # If it's an Ollama-compatible record, just return that
        model_out = {
            "name": f"{label.type}::{label.id}::{model.human_id}",
            "model": model.human_id,
            "digest": compute_hash(),
            "size": 0,
            # TODO: Figure out when to append "Z", and why it isn't appended sometimes.
            "modified_at": model.first_seen_at.isoformat() + "Z",
            "details": {
                "parent_model": "",
                "format": "gguf",
            },
            "model_identifiers": model.model_identifiers,
            "provider_identifiers": model.provider_identifiers,
        }

        yield model_out


def install_forwards(router_ish: FastAPI):
    @router_ish.get("/providers/any/any/ollama/{ollama_get_path:path}")
    async def ollama_get(
            original_request: Request,
            ollama_get_path: str,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        if ollama_get_path == "api/tags":
            collected_model_info = []
            for label, provider in ProviderRegistry().by_label.items():
                collected_model_info.extend(
                    [m async for m in emulate_api_tags(label, provider)]
                )

            return {"models": collected_model_info}

        raise HTTPException(501, "\"any\" provider_id not implemented")

    @router_ish.get("/providers/{provider_type:str}/{provider_id:path}/ollama/{ollama_get_path:path}")
    @router_ish.get("/providers/{provider_type:str}/{provider_id:path}/ollama/{ollama_post_path:path}")
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
            return {"models": [m async for m in emulate_api_tags(label, provider)]}

        if ollama_post_path == "api/show":
            request_content_json: dict = orjson.loads(await original_request.body())
            return await do_api_show(request_content_json['name'], history_db, audit_db)

        return await forward_request(original_request, audit_db)

    @router_ish.head("/providers/{provider_type:str}/{provider_id:path}/ollama/")
    async def ollama_head(
            original_request: Request,
            provider_type: ProviderType,
            provider_id: ProviderID,
    ):
        """
        This implementation isn't correct, but clients only check "HEAD /", anyway.
        """
        pass
