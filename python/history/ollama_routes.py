import logging

import httpx
from fastapi import APIRouter, Depends, FastAPI, Request
from starlette.background import BackgroundTask
from starlette.responses import StreamingResponse

from access.ratelimits import RatelimitsDB, RequestInterceptor
from access.ratelimits import get_db as get_ratelimits_db
from history.database import HistoryDB, get_db as get_history_db
from history.ollama_models import build_executor_record, build_model_from_api_show
from inference.routes import forward_request, forward_request_nodetails

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
    pass


async def do_api_show(
        original_request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
):
    intercept = RequestInterceptor(logger, ratelimits_db)

    urlpath_noprefix = original_request.url.path.removeprefix("/ollama-proxy")
    logger.debug(f"/ollama-proxy: start handler for {original_request.method} {urlpath_noprefix}")

    proxy_url = httpx.URL(path=urlpath_noprefix,
                          query=original_request.url.query.encode("utf-8"))
    upstream_request = _real_ollama_client.build_request(
        method=original_request.method,
        url=proxy_url,
        content=intercept.wrap_request_content(original_request.stream()),
        headers=original_request.headers,
        cookies=original_request.cookies,
    )

    upstream_response = await _real_ollama_client.send(upstream_request)
    intercept.build_access_event(upstream_response, api_bucket=f"ollama:{urlpath_noprefix}")

    async def on_done_fetching():
        await upstream_response.aclose()
        intercept.consolidate_json_response()
        intercept.update_access_event()

        # Once we've received all the data we're going to, persist the model info
        request_json = intercept.request_content_as_json()
        if not request_json:
            logger.info(f"Failed to log request, JSON invalid: {urlpath_noprefix}")
            return

        human_id = request_json.get('name', "")
        if not human_id:
            logger.info(f"Failed to log request, JSON incomplete: {urlpath_noprefix}")
            return

        executor_record = build_executor_record(str(_real_ollama_client.base_url), history_db=history_db)
        model = build_model_from_api_show(
            executor_record,
            human_id,
            intercept.new_access.accessed_at,
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


def install_forwards(app: FastAPI):
    ollama_forwarder = APIRouter()

    @ollama_forwarder.head("/ollama-proxy/{path:path}")
    async def do_proxy_get_post(
            request: Request,
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        """
        Don't even bother logging HEAD requests.
        """
        return await forward_request_nodetails(request, ratelimits_db)

    @ollama_forwarder.get("/ollama-proxy/{path:path}")
    @ollama_forwarder.post("/ollama-proxy/{path:path}")
    async def do_proxy_get_post(
            request: Request,
            history_db: HistoryDB = Depends(get_history_db),
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        # if request.url.path == "/ollama-proxy/api/tags":
        #     return await do_api_tags(request, history_db, ratelimits_db)

        if request.url.path == "/ollama-proxy/api/show":
            return await do_api_show(request, history_db, ratelimits_db)

        return await forward_request(request, ratelimits_db)

    app.include_router(ollama_forwarder)
