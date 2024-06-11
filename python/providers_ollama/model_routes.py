import logging
from typing import cast, Generator, Iterable, AsyncGenerator

import httpx
import orjson
import starlette.responses
import starlette.responses
import starlette.responses
import starlette.responses
from fastapi import Request

import providers
import providers_ollama
from _util.json import safe_get
from _util.typing import InferenceModelHumanID
from audit.http import AuditDB
from providers.inference_models.database import HistoryDB
from providers.inference_models.orm import InferenceModelRecord, InferenceModelRecordOrm, inject_inference_stats, \
    InferenceModelResponse
from providers.orm import ProviderLabel
from providers.registry import ProviderRegistry, BaseProvider
from providers_ollama.json import OllamaEventBuilder
from providers_ollama.models import build_model_from_api_show, build_models_from_api_tags

_real_ollama_client = httpx.AsyncClient(
    base_url="http://localhost:11434",
    http2=True,
    proxy=None,
    cert=None,
    timeout=httpx.Timeout(2.0, read=None),
    max_redirects=0,
    follow_redirects=False,
)

logger = logging.getLogger(__name__)


async def do_list_available_models(
        # TODO :circular import
        provider: "providers.ollama.ExternalOllamaProvider",
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> AsyncGenerator[InferenceModelResponse, None]:
    intercept = OllamaEventBuilder("ollama:/api/tags", audit_db)
    cached_accessed_at = intercept.wrapped_event.accessed_at

    upstream_request = provider.client.build_request(
        method="GET",
        url="/api/tags",
        # https://github.com/encode/httpx/discussions/2959
        # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
        headers=[('Connection', 'close')],
    )
    response: httpx.Response = await provider.client.send(upstream_request)
    response: starlette.responses.Response = await intercept.wrap_response(response)

    available_models_generator: Generator[InferenceModelRecord, None, None] = \
        build_models_from_api_tags(
            await provider.make_record(),
            cached_accessed_at,
            orjson.loads(response.body),
            history_db=history_db,
        )

    async def api_show_injector(
            inference_models: Generator[InferenceModelRecord, None, None]
    ) -> Generator[InferenceModelRecord, None, None]:
        inference_model: InferenceModelRecord
        for inference_model in inference_models:
            inference_model_orm: InferenceModelRecordOrm
            inference_model_orm = await do_api_show(inference_model.human_id, history_db, audit_db)
            yield InferenceModelRecord.from_orm(inference_model_orm)

    # NB This sorting is basically useless, because we don't have a way to sort models across providers.
    # NB Swift JSON decode does not preserve order, because JSON dict spec does not preserve order.
    models_and_sort_keys: Iterable[tuple[InferenceModelResponse, tuple]] = \
        inject_inference_stats(
            [amodel async for amodel in api_show_injector(available_models_generator)],
            history_db)

    for mask in models_and_sort_keys:
        yield mask[0]


async def do_api_tags(
        original_request: Request,
        history_db: HistoryDB,
        audit_db: AuditDB,
):
    logger.debug(f"ollama proxy: start handler for GET /api/tags")
    intercept = OllamaEventBuilder("ollama:/api/tags", audit_db)
    cached_accessed_at = intercept.wrapped_event.accessed_at

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


async def do_api_show(
        model_name: InferenceModelHumanID,
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> InferenceModelRecordOrm:
    intercept = OllamaEventBuilder("ollama:/api/show", audit_db)
    logger.debug(f"ollama proxy: start handler for POST /api/show")

    provider: BaseProvider = ProviderRegistry().by_label[
        ProviderLabel(type="ollama", id=str(_real_ollama_client.base_url))]
    provider: providers_ollama.registry.ExternalOllamaProvider = cast(providers_ollama.registry.ExternalOllamaProvider, provider)
    upstream_request = provider.client.build_request(
        method="POST",
        url="/api/show",
        content=orjson.dumps(
            intercept.wrap_request({"name": model_name})
        ),
        # https://github.com/encode/httpx/discussions/2959
        # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
        headers=[('Connection', 'close')],
    )
    response: httpx.Response = await provider.client.send(upstream_request)
    response: starlette.responses.Response = await intercept.wrap_response(response)

    return build_model_from_api_show(
        model_name,
        (await provider.make_record()).identifiers,
        orjson.loads(response.body),
        history_db,
    )


async def do_api_show_streaming(
        original_request: Request,
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> starlette.responses.Response:
    intercept = OllamaEventBuilder("ollama:/api/show", audit_db)
    logger.debug(f"ollama proxy: start legacy streaming handler for POST /api/show")

    provider: BaseProvider = ProviderRegistry().by_label[
        ProviderLabel(type="ollama", id=str(_real_ollama_client.base_url))
    ]
    provider: providers.ollama.ExternalOllamaProvider = cast(providers.ollama.ExternalOllamaProvider, provider)
    upstream_request = provider.client.build_request(
        method="POST",
        url="/api/show",
        content=intercept.wrap_streaming_request(original_request.stream()),
        # https://github.com/encode/httpx/discussions/2959
        # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
        headers=[('Connection', 'close')],
    )

    upstream_response = await provider.client.send(upstream_request)
    # Stash the model name, since we bothered to intercept it
    human_id = safe_get(intercept.wrapped_event.request_info, 'name')

    async def on_done_fetching(response_content_json):
        if not human_id:
            logger.info(f"ollama /api/show: Failed to log initial request, JSON incomplete")
            return

        provider: BaseProvider = ProviderRegistry().by_label[
            ProviderLabel(type="ollama", id=str(_real_ollama_client.base_url))]
        build_model_from_api_show(
            human_id,
            (await provider.make_record()).identifiers,
            response_content_json,
            history_db,
        )

    return await intercept.wrap_response(upstream_response, on_done_fetching)
