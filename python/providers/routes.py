import fastapi
import starlette.requests
from fastapi import Depends
from starlette.responses import RedirectResponse

from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.orm import ProviderType, ProviderID, ProviderLabel
from providers.registry import ProviderRegistry


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.get("/providers")
    def list_providers(
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        record_by_provider = dict([(v, k) for k, v in registry.by_record.items()])

        for label, provider in registry.by_label.items():
            record = record_by_provider[provider]
            yield label, record

    @router_ish.get("/providers/{provider_type:str}/{provider_id}")
    def get_provider(
            provider_type: ProviderType,
            provider_id: ProviderID,
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        label = ProviderLabel(type=provider_type, id=provider_id)
        provider = registry.by_label[label]

        record_by_provider = dict([(v, k) for k, v in registry.by_record.items()])

        record = record_by_provider[provider]
        return label, record

    @router_ish.get("/providers/any/any/models")
    async def get_all_provider_models(
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        async def list_models():
            for provider in registry.by_label.values():
                for model in (await provider.list_models()).values():
                    yield model

        return enumerate([m async for m in list_models()])

    @router_ish.get("/providers/{provider_type:str}/{provider_id:str}/models")
    async def get_provider_models(
            provider_type: ProviderType,
            provider_id: ProviderID,
            registry: ProviderRegistry = Depends(ProviderRegistry),
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ):
        label = ProviderLabel(type=provider_type, id=provider_id)
        provider = registry.by_label[label]

        return await provider.list_models()

    @router_ish.get("/models/available")
    async def list_available_models(
            request: starlette.requests.Request,
            provider: ProviderLabel = ProviderLabel(
                type="ollama",
                id="http://localhost:11434",
            ),
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ):
        constructed_url = request.url_for(
            'get_provider_models',
            provider_type=provider.type,
            provider_id=provider.id,
        )

        return RedirectResponse(constructed_url)
