"""
HTTP request/response streaming is consolidated here.

Main points in common:

- nearly everything streams JSON output, almost compatible with the OpenAI APIs
- the streams are encoded/decoded from bytes <-> str <-> JSON, and we virtually never care about non-JSON content
- it would be ideal to only have one copy of the request/response at any given time, but memory sharing is a little complex

Other angles that are important but not handled:

- Python sync/async generators/iterators/iterables
- Underlying httpx/starlette content objects, and how _they_ stream the above types
"""
import asyncio
import logging
from collections.abc import AsyncIterable
from datetime import datetime, timezone
from typing import Callable, AsyncIterator, TypeVar, Any, TypeAlias

import orjson
import starlette.datastructures
import starlette.requests
from starlette.background import BackgroundTask
from starlette.responses import StreamingResponse, JSONResponse

logger = logging.getLogger(__name__)

T = TypeVar('T')
U = TypeVar('U')


class NDJSONStreamingResponse(StreamingResponse, JSONResponse):
    def __init__(
            self,
            content: AsyncIterable[T],
            status_code: int = 200,
            headers: starlette.datastructures.MutableHeaders | dict[str, str] | None = None,
            media_type: str | None = None,
            background: BackgroundTask | None = None,
    ) -> None:
        super().__init__(content, status_code, headers, media_type, background)

        self._content_iterable: AsyncIterable[T] = content

        async def body_iterator() -> AsyncIterable[bytes]:
            async for content_ in self._content_iterable:
                if isinstance(content_, bytes):
                    yield content_
                else:
                    # Without newline after each chunk, it's just hard for the client to parse.
                    rendered_content: bytes = orjson.dumps(content_)
                    if rendered_content is not None and len(rendered_content) > 0:
                        yield rendered_content + b'\n'

        self.body_iterator = body_iterator()
        self.status_code = status_code
        if media_type is not None:
            self.media_type = media_type
        self.background = background
        self.init_headers(headers)


JSONStreamingResponse: TypeAlias = NDJSONStreamingResponse


async def emit_keepalive_chunks(
        primordial: AsyncIterator[U],
        timeout: float | None,
        sentinel: T,
) -> AsyncIterator[U | T]:
    # Emit an initial keepalive, in case our async chunks are enormous
    yield sentinel

    maybe_next: asyncio.Future[U] | None = None

    try:
        maybe_next = asyncio.ensure_future(primordial.__anext__())
        while True:
            try:
                yield await asyncio.wait_for(asyncio.shield(maybe_next), timeout)
                maybe_next = asyncio.ensure_future(primordial.__anext__())
            except asyncio.TimeoutError:
                yield sentinel

    except StopAsyncIteration:
        pass

    finally:
        if maybe_next is not None:
            maybe_next.cancel()


async def emit_keepalive_chunks_with_log(
        primordial: AsyncIterator[U],
        timeout: float | None,
        sentinel: T,
        emit_logger_fn: Callable[[str], Any],
) -> AsyncIterator[U | T]:
    start_time = datetime.now(tz=timezone.utc)

    async for item in emit_keepalive_chunks(primordial, timeout, sentinel):
        yield item

        if item == sentinel:
            current_time = datetime.now(tz=timezone.utc)
            time_desc = f"{(current_time - start_time).total_seconds():.6f}"
            emit_logger_fn(f"emit_keepalive_chunks(): emitting sentinel after {time_desc}")
