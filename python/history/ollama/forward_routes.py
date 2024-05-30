import logging
from typing import Awaitable, Callable, Any

import httpx
import starlette.requests
from fastapi import Request
from starlette.background import BackgroundTask
from starlette.responses import StreamingResponse
from typing_extensions import deprecated

from audit.http import AuditDB
from audit.http_raw import HttpxLogger
from providers.ollama import _real_ollama_client
from history.ollama.json import OllamaEventBuilder, OllamaResponseContentJSON

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
        # Purposely ignore the headers, because we don't want to pass the `host` around.
        headers=None,
        cookies=original_request.cookies,
    )

    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)

    async def real_on_done():
        await upstream_response.aclose()
        if on_done_fn is not None:
            await on_done_fn()

    return StreamingResponse(
        content=upstream_response.aiter_raw(),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(real_on_done),
    )


@deprecated("Clients should migrate to `nolog`, which makes behavior changes explicit")
async def forward_request_nodetails(
        original_request: Request,
        _: AuditDB,
):
    urlpath_noprefix = original_request.url.path.removeprefix("/ollama-proxy")
    logger.debug(f"ollama proxy: start nodetails handler for {original_request.method} {urlpath_noprefix}")

    proxy_url = httpx.URL(path=urlpath_noprefix,
                          query=original_request.url.query.encode("utf-8"))

    return await forward_request_nolog(proxy_url, original_request)


async def forward_request(
        original_request: starlette.requests.Request,
        audit_db: AuditDB,
        on_done_fn: Callable[[OllamaResponseContentJSON], Awaitable[Any]] | None = None,
) -> starlette.responses.StreamingResponse:
    urlpath_noprefix = original_request.url.path.removeprefix("/ollama-proxy")
    logger.debug(f"ollama proxy: start handler for {original_request.method} {urlpath_noprefix}")

    intercept = OllamaEventBuilder(f"ollama:{urlpath_noprefix}", audit_db)
    if original_request.url.query:
        raise NotImplementedError(f"Haven't implemented anything to handle query args in {original_request}")

    upstream_request = _real_ollama_client.build_request(
        method=original_request.method,
        url=urlpath_noprefix,
        content=intercept.wrap_req(original_request.stream()),
        headers=None,
        cookies=original_request.cookies,
    )

    with HttpxLogger(_real_ollama_client, audit_db):
        upstream_response: httpx.Response = await _real_ollama_client.send(upstream_request, stream=True)

    return await intercept.wrap_entire_streaming_response(upstream_response, on_done_fn)
