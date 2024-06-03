import itertools
import logging
import operator
from typing import cast, Any

import httpx
import orjson
import starlette.responses
from fastapi import Request

import providers
from _util.json import safe_get
from _util.typing import InferenceModelRecordID, InferenceModelHumanID
from audit.http import AuditDB
from history.ollama.json import OllamaEventBuilder
from history.ollama.models import build_model_from_api_show, build_models_from_api_tags
from providers.inference_models.database import HistoryDB
from providers.inference_models.orm import InferenceModelRecord, InferenceModelRecordOrm, inject_inference_stats
from providers.ollama import OllamaProvider
from providers.orm import ProviderLabel
from providers.registry import ProviderRegistry, BaseProvider

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
        provider: OllamaProvider,
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> dict[int, InferenceModelRecord | Any]:
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

    available_models_generator = build_models_from_api_tags(
        await provider.make_record(),
        cached_accessed_at,
        orjson.loads(response.body),
        history_db=history_db,
    )
    models_and_sort_keys = inject_inference_stats(available_models_generator, history_db)

    # NB Swift JSON decode does not preserve order, because JSON does not preserve order
    sorted_masks = sorted(models_and_sort_keys, key=operator.itemgetter(1), reverse=True)
    dicted_masks = dict(
        [(index, model) for index, (model, sort_key) in enumerate(sorted_masks)]
    )
    for k, v in itertools.islice(dicted_masks.items(), 5):
        logger.debug(f"InferenceModel #{k}: {v.stats}")

    return dicted_masks


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
        content=intercept.wrap_req(original_request.stream()),
        headers=original_request.headers,
        cookies=original_request.cookies,
    )

    async def on_done_fetching(response_content_json):
        provider = ProviderRegistry().by_label[ProviderLabel(type="ollama", id=_real_ollama_client.base_url)]
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

    provider: BaseProvider = ProviderRegistry().by_label[ProviderLabel(type="ollama", id=str(_real_ollama_client.base_url))]
    provider: providers.ollama.OllamaProvider = cast(providers.ollama.OllamaProvider, provider)
    upstream_request = provider.client.build_request(
        method="POST",
        url="/api/show",
        content=orjson.dumps({"name": model_name}),
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
    logger.debug(f"ollama proxy: start legacy handler for POST /api/show")

    provider: BaseProvider = ProviderRegistry().by_label[
        ProviderLabel(type="ollama", id=str(_real_ollama_client.base_url))
    ]
    provider: providers.ollama.OllamaProvider = cast(providers.ollama.OllamaProvider, provider)
    upstream_request = provider.client.build_request(
        method="POST",
        url="/api/show",
        content=intercept.wrap_req(original_request.stream()),
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
