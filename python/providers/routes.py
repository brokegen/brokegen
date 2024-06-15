import asyncio
from typing import AsyncGenerator, Iterable, Awaitable, AsyncIterable

import fastapi
from fastapi import Depends
from starlette.responses import RedirectResponse

from providers.inference_models.orm import InferenceModelResponse, InferenceModelRecord
from providers.orm import ProviderType, ProviderID, ProviderLabel, ProviderRecord
from providers.registry import ProviderRegistry, BaseProvider


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.get("/providers")
    def list_any_providers(
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ) -> Iterable[tuple[ProviderLabel, ProviderRecord]]:
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
        discoverers: list[Awaitable[None]] = [
            factory.discover(provider_type=None, registry=registry)
            for factory in registry.factories
        ]
        for done in asyncio.as_completed(discoverers):
            _ = await done

        return RedirectResponse(
            request.url_for('list_any_providers')
        )

    @router_ish.get("/providers/{provider_type:str}/any/.discover")
    async def discover_specific_providers(
            provider_type: ProviderType,
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        async def do_load() -> AsyncGenerator[tuple[ProviderLabel, ProviderRecord], None]:
            for factory in registry.factories:
                await factory.discover(provider_type, registry=registry)

            for label, provider in registry.by_label.items():
                yield get_provider(label.type, label.id, registry)

        return [(pt[0], pt[1]) async for pt in do_load()]

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
    ) -> list[InferenceModelResponse]:
        """
        This returns a set of ordered pairs, to reflect how the models should be ranked to the user.

        TODO:  client doesn't check the ordering anymore, and neither should we.
        """

        async def generator_to_awaitable(
                label: ProviderLabel,
                provider: BaseProvider,
        ) -> list[InferenceModelResponse]:
            def to_response(model: InferenceModelRecord | InferenceModelResponse):
                if isinstance(model, InferenceModelResponse):
                    return model
                else:
                    new_imr = InferenceModelResponse(**model.model_dump())
                    if new_imr.label is None:
                        new_imr.label = label

                    return new_imr

            return [to_response(model) async for model in provider.list_models()]

        async def list_models_per_provider() -> AsyncIterable[list[InferenceModelResponse]]:
            model_listers: list[Awaitable[list[InferenceModelResponse]]] = [
                generator_to_awaitable(label, provider)
                for label, provider in registry.by_label.items()
            ]

            for done_list in asyncio.as_completed(model_listers):
                yield await done_list

        # Flatten the list of lists that we got
        return [model
                async for model_list in list_models_per_provider()
                for model in model_list]

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
