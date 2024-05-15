import logging
from datetime import datetime, timezone

import httpx
from fastapi import Request
from starlette.background import BackgroundTask
from starlette.responses import StreamingResponse

from access.ratelimits import RatelimitsDB, RequestInterceptor, ApiAccessWithResponse

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


async def forward_request_nodetails(
        original_request: Request,
        ratelimits_db: RatelimitsDB,
):
    """
    Implements a simple proxy, as stream-y as possible

    https://github.com/tiangolo/fastapi/issues/1788#issuecomment-1320916419
    """
    urlpath_noprefix = original_request.url.path.removeprefix("/ollama-proxy")
    logger.debug(f"/ollama-proxy: start nolog handler for {original_request.method} {urlpath_noprefix}")

    proxy_url = httpx.URL(path=urlpath_noprefix,
                          query=original_request.url.query.encode("utf-8"))
    upstream_request = _real_ollama_client.build_request(
        method=original_request.method,
        url=proxy_url,
        content=original_request.stream(),
        headers=original_request.headers,
        cookies=original_request.cookies,
    )

    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)
    new_access = ApiAccessWithResponse(
        api_bucket=f"ollama:{urlpath_noprefix}",
        accessed_at=datetime.now(tz=timezone.utc),
        api_endpoint=str(upstream_response.request.url),
        request={
            'method': upstream_response.request.method,
            'url': str(upstream_response.request.url),
            'headers': upstream_response.request.headers.multi_items().sort(),
        },
        response={
            'status_code': upstream_response.status_code,
            'headers': upstream_response.headers.multi_items().sort(),
        },
    )
    ratelimits_db.add(new_access)
    ratelimits_db.commit()

    return StreamingResponse(
        upstream_response.aiter_raw(),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(upstream_response.aclose),
    )


async def forward_request(
        original_request: Request,
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

    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)
    intercept.generate_api_access(upstream_response, api_bucket=f"ollama:{urlpath_noprefix}")

    async def post_forward_cleanup():
        await upstream_response.aclose()
        intercept._consolidate_content()
        intercept.update_api_access_content()

    # TODO: Provide an exception handler that returns an HTTP error to the client,
    #       especially for cases where we KeyboardInterrupt.
    return StreamingResponse(
        # content=intercept.wrap_response_content_raw(upstream_response.aiter_raw()),
        content=intercept.wrap_response_content(upstream_response.aiter_lines()),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(post_forward_cleanup),
    )
