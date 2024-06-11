from typing import AsyncGenerator

import fastapi
from fastapi import Depends
from starlette.responses import RedirectResponse

from providers.inference_models.orm import InferenceModelResponse
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

    @router_ish.get("/providers/any/.discover")
    async def discover_any_providers(
            request: fastapi.Request,
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        """
        This method is an HTTP GET, because we do a redirect once the discovery process is done.
        """
        for factory in registry.factories:
            await factory.discover(provider_type=None, registry=registry)

        return RedirectResponse(
            request.url_for('list_providers')
        )

    @router_ish.post("/providers/{provider_type:str}/.discover")
    async def discover_providers(
            provider_type: ProviderType,
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        for factory in registry.factories:
            await factory.discover(provider_type, registry)

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
        async def list_models() -> AsyncGenerator[InferenceModelResponse, None]:
            for label, provider in registry.by_label.items():
                async for model in provider.list_models():
                    new_imr = InferenceModelResponse(**model.model_dump())
                    if new_imr.label is None:
                        new_imr.label = label

                    yield new_imr

        return enumerate([m async for m in list_models()])

    @router_ish.get("/providers/{provider_type:str}/any/models")
    async def get_all_provider_models(
            provider_type: ProviderType,
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        async def list_models() -> AsyncGenerator[InferenceModelResponse, None]:
            for label, provider in registry.by_label.items():
                if label.type != provider_type:
                    continue

                async for model in provider.list_models():
                    new_imr = InferenceModelResponse(**model.model_dump())
                    if new_imr.label is None:
                        new_imr.label = label

                    yield new_imr

        return enumerate([m async for m in list_models()])

    @router_ish.get("/providers/{provider_type:str}/{provider_id:path}/models")
    async def get_provider_models(
            provider_type: ProviderType,
            provider_id: ProviderID,
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        async def list_models() -> AsyncGenerator[InferenceModelResponse, None]:
            label = ProviderLabel(type=provider_type, id=provider_id)
            provider = registry.by_label[label]

            async for model in provider.list_models():
                new_imr = InferenceModelResponse(**model.model_dump())
                if new_imr.label is None:
                    new_imr.label = label

                yield new_imr

        return enumerate([m async for m in list_models()])
