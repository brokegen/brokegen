import asyncio
import logging
from typing import AsyncGenerator, Iterable, Awaitable, AsyncIterable, Annotated

import fastapi
from fastapi import Depends, Query
from starlette.responses import RedirectResponse

from client.database import HistoryDB, get_db as get_history_db
from .foundation_models.orm import FoundationModelResponse, FoundationModelRecord, inject_inference_stats
from .orm import ProviderType, ProviderID, ProviderLabel, ProviderRecord
from .registry import ProviderRegistry, BaseProvider

logger = logging.getLogger(__name__)


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

    @router_ish.get("/providers/{provider_type:str}/.discover")
    async def discover_specific_providers(
            provider_type: ProviderType,
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        async def do_load() -> AsyncGenerator[tuple[ProviderLabel, ProviderRecord], None]:
            for factory in registry.factories:
                await factory.discover(provider_type, registry=registry)

            for label, provider in registry.by_label.items():
                if label.type == provider_type:
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
            bypass_cache: Annotated[bool, Query()] = False,
            history_db: HistoryDB = Depends(get_history_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ) -> list[FoundationModelResponse]:
        """
        This returns a set of ordered pairs, to reflect how the models should be ranked to the user.
        TODO:  client doesn't check the ordering anymore, and neither should we.

        NB This sorting is basically useless, because we don't have a way to sort models across providers.
        NB Swift JSON decode does not preserve order, because JSON dict spec does not preserve order.
        """

        async def generator_to_awaitable(
                label: ProviderLabel,
                provider: BaseProvider,
        ) -> list[tuple[FoundationModelRecord, ProviderLabel]]:
            if bypass_cache:
                list_maker: AsyncGenerator[FoundationModelRecord, None] = provider.list_models_nocache()
            else:
                list_maker: AsyncGenerator[FoundationModelRecord, None] = provider.list_models()

            available_models = [(model, label) async for model in list_maker]

            logger.info(f"{len(available_models)} available FoundationModels <= from {label}")
            return available_models

        async def list_models_per_provider() -> AsyncIterable[
            list[tuple[FoundationModelRecord, ProviderLabel]]
        ]:
            model_listers: list[Awaitable[
                list[tuple[FoundationModelRecord, ProviderLabel]]
            ]]

            model_listers = [
                generator_to_awaitable(label, provider)
                for label, provider in registry.by_label.items()
            ]

            for done_list in asyncio.as_completed(model_listers):
                yield await done_list

        # Flatten the list of lists that we got
        all_models = [
            inject_inference_stats(model, label, history_db)
            async for model_list in list_models_per_provider()
            for model, label in model_list
        ]

        return all_models

    @router_ish.get("/providers/{provider_type:str}/any/models")
    async def get_all_provider_models(
            provider_type: ProviderType,
            history_db: HistoryDB = Depends(get_history_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        async def generator_to_awaitable(
                label: ProviderLabel,
                provider: BaseProvider,
        ) -> list[tuple[FoundationModelRecord, ProviderLabel]]:
            list_maker: AsyncGenerator[FoundationModelRecord, None] = provider.list_models()
            return [(model, label) async for model in list_maker]

        async def list_models() -> AsyncIterable[FoundationModelRecord]:
            for label, provider in registry.by_label.items():
                if label.type != provider_type:
                    continue

                for model, label in await generator_to_awaitable(label, provider):
                    yield inject_inference_stats(model, label, history_db)

        return [m async for m in list_models()]

    @router_ish.get("/providers/{provider_type:str}/{provider_id:path}/models")
    async def get_provider_models(
            provider_type: ProviderType,
            provider_id: ProviderID,
            history_db: HistoryDB = Depends(get_history_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        async def list_models() -> AsyncIterable[FoundationModelRecord]:
            label = ProviderLabel(type=provider_type, id=provider_id)
            provider = registry.by_label[label]

            list_maker: AsyncGenerator[FoundationModelRecord, None] = provider.list_models()
            for model in await list_maker:
                yield inject_inference_stats(model, label, history_db)

        return [m async for m in list_models()]
