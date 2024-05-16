import logging

import httpx
from fastapi import Request
from starlette.background import BackgroundTask
from starlette.responses import StreamingResponse

from access.ratelimits import RatelimitsDB
from history.ollama.json import JSONRequestInterceptor
from history.database import HistoryDB
from history.ollama.models import build_executor_record, build_model_from_api_show, build_models_from_api_tags

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
        ratelimits_db: RatelimitsDB,
):
    intercept = JSONRequestInterceptor(logger, ratelimits_db)

    logger.debug(f"ollama proxy: start handler for GET /api/tags")
    upstream_request = _real_ollama_client.build_request(
        method=original_request.method,
        url="/api/tags",
        content=intercept.wrap_request_content(original_request.stream()),
        headers=original_request.headers,
        cookies=original_request.cookies,
    )

    upstream_response = await _real_ollama_client.send(upstream_request)
    intercept.build_access_event(upstream_response, api_bucket=f"ollama:/api/tags")

    async def on_done_fetching():
        await upstream_response.aclose()
        await intercept.consolidate_json_response()
        intercept.update_access_event()

        executor_record = build_executor_record(str(_real_ollama_client.base_url), history_db=history_db)
        build_models_from_api_tags(
            executor_record,
            intercept.new_access.accessed_at,
            intercept.response_content_as_json(),
            history_db=history_db,
        )

    return StreamingResponse(
        content=intercept.wrap_response_content(upstream_response.aiter_lines()),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(on_done_fetching),
    )


async def do_api_show(
        original_request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
):
    intercept = JSONRequestInterceptor(logger, ratelimits_db)

    logger.debug(f"ollama proxy: start handler for POST /api/show")
    upstream_request = _real_ollama_client.build_request(
        method=original_request.method,
        url="/api/show",
        content=intercept.wrap_request_content(original_request.stream()),
        headers=original_request.headers,
        cookies=original_request.cookies,
    )

    upstream_response = await _real_ollama_client.send(upstream_request)
    intercept.build_access_event(upstream_response, api_bucket=f"ollama:/api/show")

    async def on_done_fetching():
        await upstream_response.aclose()
        await intercept.consolidate_json_response()
        intercept.update_access_event()

        # Once we've received all the data we're going to, persist the model info
        request_json = intercept.request_content_as_json()
        if not request_json:
            logger.info(f"ollama /api/show: Failed to log request, JSON invalid")
            return

        human_id = request_json.get('name', "")
        if not human_id:
            logger.info(f"ollama /api/show: Failed to log request, JSON incomplete")
            return

        executor_record = build_executor_record(str(_real_ollama_client.base_url), history_db=history_db)
        model = build_model_from_api_show(
            executor_record,
            human_id,
            intercept.new_access.accessed_at,
            # TODO: Figure out a good interface to do this as str
            intercept.response_content_as_json(),
            history_db=history_db,
        )

        return model

    return StreamingResponse(
        content=intercept.wrap_response_content(upstream_response.aiter_lines()),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(on_done_fetching),
    )
