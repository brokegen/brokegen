import logging

import httpx
from fastapi import APIRouter, Depends, FastAPI, Request
from starlette.background import BackgroundTask
from starlette.responses import StreamingResponse

from access.ratelimits import RatelimitsDB, RequestInterceptor
from access.ratelimits import get_db as get_ratelimits_db

_real_ollama_client = httpx.AsyncClient(
    base_url="http://localhost:11434",
    http2=True,
    proxy=None,
    timeout=None,
    max_redirects=0,
    follow_redirects=False,
)

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)


async def forward_request_nolog(request: Request):
    """
    Implements a simple proxy, as stream-y as possible

    https://github.com/tiangolo/fastapi/issues/1788#issuecomment-1320916419
    """
    urlpath_noprefix = request.url.path.removeprefix("/ollama-proxy")
    logger.debug(f"/ollama-proxy: {request.method} {urlpath_noprefix}")

    url = httpx.URL(path=urlpath_noprefix,
                    query=request.url.query.encode("utf-8"))
    rp_req = _real_ollama_client.build_request(
        request.method,
        url,
        headers=request.headers.raw,
        content=request.stream(),
    )
    upstream_response = await _real_ollama_client.send(rp_req, stream=True)
    return StreamingResponse(
        upstream_response.aiter_raw(),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(upstream_response.aclose),
    )


async def forward_request(
        request: Request,
        ratelimits_db: RatelimitsDB,
):
    intercept = RequestInterceptor(logger, ratelimits_db)

    urlpath_noprefix = request.url.path.removeprefix("/ollama-proxy")
    logger.debug(f"/ollama-proxy: {request.method} {urlpath_noprefix}")

    url = httpx.URL(path=urlpath_noprefix,
                    query=request.url.query.encode("utf-8"))
    upstream_request = _real_ollama_client.build_request(
        request.method,
        url,
        headers=request.headers.raw,
        content=intercept.wrap_request_content(request.stream()),
    )

    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)
    intercept.generate_api_access(upstream_response, api_bucket=__name__)

    async def post_forward_cleanup():
        await upstream_response.aclose()
        intercept.update_api_access_content()

    return StreamingResponse(
        intercept.wrap_response_content(upstream_response),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(post_forward_cleanup),
    )


def install_proxy_routes(app: FastAPI):
    ollama_forwarder = APIRouter()

    @ollama_forwarder.head("/ollama-proxy/{path:path}")
    async def do_proxy_head(request: Request):
        """
        Don't bother logging HEAD requests, since they aren't _supposed_ to encode anything
        """
        return await forward_request_nolog(request)

    # TODO: Either OpenAPI or FastAPI doesn't parse these `{path:path}` directives correctly
    @ollama_forwarder.post("/ollama-proxy/{path:path}")
    @ollama_forwarder.get("/ollama-proxy/{path:path}")
    async def do_proxy_get_post(
            request: Request,
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        return await forward_request(request, ratelimits_db)

    app.include_router(ollama_forwarder)
