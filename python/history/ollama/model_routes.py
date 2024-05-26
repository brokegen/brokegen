import logging

import httpx
from fastapi import Request

from audit.http import AuditDB
from history.ollama.json import OllamaEventBuilder
from history.ollama.models import build_model_from_api_show, build_models_from_api_tags
from providers.ollama import build_executor_record
from providers.database import HistoryDB
from history.shared.json import safe_get

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
        executor_record = build_executor_record(str(_real_ollama_client.base_url), history_db=history_db)
        build_models_from_api_tags(
            executor_record,
            cached_accessed_at,
            response_content_json,
            history_db=history_db,
        )

    upstream_response = await _real_ollama_client.send(upstream_request)
    return await intercept.wrap_response(upstream_response, on_done_fetching)


async def do_api_show(
        original_request: Request,
        history_db: HistoryDB,
        audit_db: AuditDB,
):
    intercept = OllamaEventBuilder("ollama:/api/show", audit_db)
    logger.debug(f"ollama proxy: start handler for POST /api/show")
    upstream_request = _real_ollama_client.build_request(
        method=original_request.method,
        url="/api/show",
        content=intercept.wrap_req(original_request.stream()),
        headers=original_request.headers,
        cookies=original_request.cookies,
    )

    # Stash the model name, since we bothered to intercept it
    model_name = safe_get(intercept.wrapped_event.request_info, 'name')

    async def on_done_fetching(response_content_json):
        if not model_name:
            logger.info(f"ollama /api/show: Failed to log request, JSON incomplete")
            return

        executor_record = build_executor_record(str(_real_ollama_client.base_url), history_db=history_db)
        model = build_model_from_api_show(
            executor_record,
            model_name,
            intercept.wrapped_event.accessed_at,
            response_content_json,
            history_db=history_db,
        )

        return model

    upstream_response = await _real_ollama_client.send(upstream_request)
    return await intercept.wrap_response(upstream_response, on_done_fetching)
