import logging
from typing import Awaitable, Callable, Any

import httpx
from fastapi import Request
from starlette.background import BackgroundTask
from starlette.responses import StreamingResponse
from typing_extensions import deprecated

from access.ratelimits import RatelimitsDB
from history.ollama.json import JSONRequestInterceptor

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


async def forward_request_nolog(
        endpoint_url: str | httpx.URL,
        original_request: Request,
        on_done_fn: Callable[[], Awaitable[Any]] | None = None,
):
    """
    Implements a simple proxy, as stream-y as possible

    https://github.com/tiangolo/fastapi/issues/1788#issuecomment-1320916419

    NB This doesn't really enable interception of data; it's simple enough, just rewrite it if you need that.
    """
    upstream_request = _real_ollama_client.build_request(
        method=original_request.method,
        url=endpoint_url,
        content=original_request.stream(),
        headers=original_request.headers,
        cookies=original_request.cookies,
    )

    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)

    async def real_on_done():
        await upstream_response.aclose()
        if on_done_fn is not None:
            await on_done_fn()

    return StreamingResponse(
        upstream_response.aiter_raw(),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(real_on_done),
    )


@deprecated("Clients should migrate to `nolog`, which makes behavior changes explicit")
async def forward_request_nodetails(
        original_request: Request,
        _: RatelimitsDB,
):
    urlpath_noprefix = original_request.url.path.removeprefix("/ollama-proxy")
    logger.debug(f"/ollama-proxy: start nodetails handler for {original_request.method} {urlpath_noprefix}")

    proxy_url = httpx.URL(path=urlpath_noprefix,
                          query=original_request.url.query.encode("utf-8"))

    return await forward_request_nolog(proxy_url, original_request)


async def forward_request(
        original_request: Request,
        ratelimits_db: RatelimitsDB,
        on_done_fn=None,
):
    intercept = JSONRequestInterceptor(logger, ratelimits_db)

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

    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)
    intercept.build_access_event(upstream_response, api_bucket=f"ollama:{urlpath_noprefix}")

    async def post_forward_cleanup():
        await upstream_response.aclose()
        await intercept.consolidate_json_response()
        intercept.update_access_event()

        if on_done_fn is not None:
            await on_done_fn(intercept.response_content_as_json())

    # TODO: Provide an exception handler that returns an HTTP error to the client,
    #       especially for cases where we KeyboardInterrupt.
    return StreamingResponse(
        # content=intercept.wrap_response_content_raw(upstream_response.aiter_raw()),
        content=intercept.wrap_response_content(upstream_response.aiter_lines()),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(post_forward_cleanup),
    )