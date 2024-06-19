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
from typing import Callable, Awaitable, AsyncIterator, TypeVar, Any
from typing import Iterable

import orjson
import starlette.datastructures
import starlette.requests
from starlette.background import BackgroundTask
from starlette.concurrency import iterate_in_threadpool
from starlette.responses import StreamingResponse, JSONResponse

from _util.json import safe_get, JSONDict
from _util.typing import InferenceModelHumanID

logger = logging.getLogger(__name__)


class JSONStreamingResponse(StreamingResponse, JSONResponse):
    def __init__(
            self,
            content: Iterable | AsyncIterable,
            status_code: int = 200,
            headers: starlette.datastructures.MutableHeaders | dict[str, str] | None = None,
            media_type: str | None = None,
            background: BackgroundTask | None = None,
    ) -> None:
        if isinstance(content, AsyncIterable):
            self._content_iterable: AsyncIterable = content
        else:
            self._content_iterable = iterate_in_threadpool(content)

        async def body_iterator() -> AsyncIterable[bytes]:
            async for content_ in self._content_iterable:
                if isinstance(content_, bytes):
                    yield content_
                else:
                    yield self.render(content_)

        self.body_iterator = body_iterator()
        self.status_code = status_code
        if media_type is not None:
            self.media_type = media_type
        self.background = background
        self.init_headers(headers)


T = TypeVar('T')
U = TypeVar('U')


async def emit_keepalive_chunks(
        primordial: AsyncIterator[U],
        timeout: float | None,
        sentinel: T,
) -> AsyncIterator[U | T]:
    start_time = datetime.now(tz=timezone.utc)
    maybe_next: asyncio.Future[U] | None = None

    # Emit an initial keepalive, in case our async chunks are enormous
    logger.debug(f"emit_keepalive_chunks(): emitting zero sentinel after {datetime.now(tz=timezone.utc) - start_time}")
    yield sentinel

    try:
        maybe_next = asyncio.ensure_future(primordial.__anext__())
        while True:
            try:
                yield await asyncio.wait_for(asyncio.shield(maybe_next), timeout)
                maybe_next = asyncio.ensure_future(primordial.__anext__())
            except asyncio.TimeoutError:
                current_time = datetime.now(tz=timezone.utc)
                logger.debug(f"emit_keepalive_chunks(): emitting sentinel after {current_time - start_time}")
                yield sentinel

    except StopAsyncIteration:
        pass

    finally:
        if maybe_next is not None:
            maybe_next.cancel()


async def consolidate_stream_to_json(primordial: AsyncIterable[str | bytes]) -> JSONDict:
    content_chunks = []
    async for chunk in primordial:
        content_chunks.append(chunk)

    # TODO: Get your bytes | str typing in order
    if not content_chunks:
        raise NotImplementedError("No content chunks returned during templating")

    if isinstance(content_chunks[0], str):
        response0_json = orjson.loads(''.join(content_chunks))
    elif isinstance(content_chunks[0], bytes):
        response0_json = orjson.loads(b''.join(content_chunks))
    else:
        logger.warning(f"Ignoring helper_fn request, {type(content_chunks[0])=}")
        raise TypeError()

    return response0_json
