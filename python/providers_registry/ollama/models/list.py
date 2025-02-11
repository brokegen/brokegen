import asyncio
import logging
from typing import cast, Generator, AsyncGenerator

import httpx
import orjson
import starlette.responses
import starlette.responses
import starlette.responses
import starlette.responses
from fastapi import Request

import providers
import providers_registry
from _util.json import safe_get
from _util.typing import FoundationModelHumanID
from audit.http import AuditDB
from client.database import HistoryDB
from providers.foundation_models.orm import FoundationModelRecord
from providers.orm import ProviderLabel
from providers.registry import ProviderRegistry, BaseProvider
from providers_registry.ollama.json import OllamaEgressEventBuilder
from .intercept import build_model_from_api_show, build_models_from_api_tags

_real_ollama_client = httpx.AsyncClient(
    base_url="http://localhost:11434",
    http2=True,
    proxy=None,
    trust_env=False,
    cert=None,
    timeout=httpx.Timeout(2.0, read=None),
    max_redirects=0,
    follow_redirects=False,
)

logger = logging.getLogger(__name__)


async def do_list_available_models(
        # TODO: circular import
        provider: "providers.ollama.ExternalOllamaProvider",
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> AsyncGenerator[FoundationModelRecord, None]:
    intercept = OllamaEgressEventBuilder("ollama:/api/tags", audit_db)
    cached_accessed_at = intercept.wrapped_event.accessed_at

    upstream_request = provider.client.build_request(
        method="GET",
        url="/api/tags",
        # https://github.com/encode/httpx/discussions/2959
        # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
        headers=[('Connection', 'close')],
        # TODO: Determine what causes ollama's /api/tags to hit a timeout, rather than hard-coding to 300 seconds.
        timeout=httpx.Timeout(300)
    )
    try:
        response: httpx.Response = await provider.client.send(upstream_request)
    except (httpx.ConnectError, httpx.ConnectTimeout) as e:
        logger.error(f"Failed to fetch new ollama models, check if ollama is running: {e}")
        return

    response: starlette.responses.Response = await intercept.wrap_response(response)

    available_models_generator: Generator[FoundationModelRecord, None, None] = \
        build_models_from_api_tags(
            await provider.make_record(),
            cached_accessed_at,
            orjson.loads(response.body),
            history_db=history_db,
        )

    async def api_show_injector(
            inference_models: Generator[FoundationModelRecord, None, None]
    ) -> AsyncGenerator[FoundationModelRecord, None]:
        inference_model: FoundationModelRecord
        for inference_model in inference_models:
            try:
                yield await do_api_show(inference_model.human_id, history_db, audit_db)

                # Allow a coro context switch, so server is more responsive during enumeration.
                await asyncio.sleep(0)

            except RuntimeError as e:
                logger.warning(f"Skipping {inference_model} in listing, {e}")
                yield inference_model

    async for amodel in api_show_injector(available_models_generator):
        yield amodel


async def do_api_tags(
        original_request: Request,
        history_db: HistoryDB,
        audit_db: AuditDB,
):
    logger.debug(f"ollama proxy: start handler for GET /api/tags")
    intercept = OllamaEgressEventBuilder("ollama:/api/tags", audit_db)
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
        inference_models = build_models_from_api_tags(
            await provider.make_record(),
            cached_accessed_at,
            response_content_json,
            history_db=history_db,
        )

        # Run an /api/show request on each /api/tags request, also.
        # Otherwise we have have-built FoundationModels, and due to how we implemented Providers, sometimes we can't access the original.
        # In particular, the model options for x86 vs arm "providers" get weird.
        for inference_model in inference_models:
            if (
                    inference_model.combined_inference_parameters is None
                    or inference_model.combined_inference_parameters == ""
                    or inference_model.combined_inference_parameters == "null"
            ):
                _ = await do_api_show(inference_model.human_id, history_db, audit_db)

    upstream_response = await _real_ollama_client.send(upstream_request)
    return await intercept.wrap_response(upstream_response, on_done_fetching)


async def do_api_show(
        model_name: FoundationModelHumanID,
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> FoundationModelRecord:
    intercept = OllamaEgressEventBuilder("ollama:/api/show", audit_db)
    logger.debug(f"ollama-proxy: start handler for POST /api/show <= {model_name}")

    provider: BaseProvider = ProviderRegistry().by_label[
        ProviderLabel(type="ollama", id=str(_real_ollama_client.base_url))]
    provider: providers_registry.ollama.registry.ExternalOllamaProvider = cast(
        providers_registry.ollama.registry.ExternalOllamaProvider, provider)
    upstream_request = provider.client.build_request(
        method="POST",
        url="/api/show",
        content=orjson.dumps(
            intercept.wrap_request({"name": model_name})
        ),
        # https://github.com/encode/httpx/discussions/2959
        # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
        headers=[('Connection', 'close')],
        # Increase the timeout for /api/show requests, because we generally call it async
        # (which means a lot of coro switching, which makes this call timeout when using `asyncio.sleep(0)`).
        timeout=httpx.Timeout(10.0, read=None),
    )
    response: httpx.Response = await provider.client.send(upstream_request)
    if response.status_code != 200:
        logger.error(f"ollama-proxy/api/show: failed with HTTP {response.status_code}")
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
    intercept = OllamaEgressEventBuilder("ollama:/api/show", audit_db)
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
