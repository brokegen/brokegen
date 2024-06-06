import urllib.parse
from typing import AsyncIterable, Any, cast, AsyncGenerator

import fastapi
import starlette.requests
from fastapi import Depends
from starlette.responses import RedirectResponse

from providers.inference_models.orm import InferenceModelRecord
from providers.openai.lm_studio import LMStudioProvider
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
        async def list_models() -> AsyncGenerator[InferenceModelRecord | Any]:
            for provider in registry.by_label.values():
                async for model in provider.list_models():
                    yield model

        return enumerate([m async for m in list_models()])

    @router_ish.get("/providers/{provider_type:str}/any/models")
    async def get_all_provider_models(
            provider_type: ProviderType,
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        async def list_models() -> AsyncIterable[InferenceModelRecord | Any]:
            for label, provider in registry.by_label.items():
                if label.type != provider_type:
                    continue

                async for model in provider.list_models():
                    yield model

        return enumerate([m async for m in list_models()])

    @router_ish.get("/providers/{provider_type:str}/{provider_id:path}/models")
    async def get_provider_models(
            provider_type: ProviderType,
            provider_id: ProviderID,
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        label = ProviderLabel(type=provider_type, id=provider_id)
        provider = registry.by_label[label]

        return await provider.list_models()

    @router_ish.get("/models/available")
    async def list_available_models(
            request: starlette.requests.Request,
            # NB According to an older HTTP/1.1 spec, GET requests should not have meaningful content.
            # So the arguments to this function might be removed by a middleman proxy, or whatever.
            provider: ProviderLabel = ProviderLabel(
                type="ollama",
                id="http://localhost:11434",
            ),
    ):
        constructed_url = request.url_for(
            'get_provider_models',
            provider_type=urllib.parse.quote_plus(provider.type),
            provider_id=urllib.parse.quote_plus(provider.id),
        )

        return RedirectResponse(constructed_url)
