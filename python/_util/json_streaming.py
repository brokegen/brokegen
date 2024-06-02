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
from typing import Callable, Awaitable, AsyncIterator, TypeVar
from typing import Iterable

import orjson
import starlette.datastructures
import starlette.requests
from starlette.background import BackgroundTask
from starlette.concurrency import iterate_in_threadpool
from starlette.responses import StreamingResponse, JSONResponse

from _util.json import safe_get, JSONDict
from _util.typing import InferenceModelHumanID
from history.ollama.json import OllamaResponseContentJSON, \
    consolidate_stream

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


async def complex_nothing_chain(
        inference_model_human_id: InferenceModelHumanID,
        is_disconnected: Callable[[], Awaitable[bool]],
):
    async def fake_timeout(
            bigsleep_sec: float = 30.1,
            bigsleep_times: int = 3,
    ) -> AsyncIterator[str]:
        for _ in range(bigsleep_times):
            await asyncio.sleep(bigsleep_sec)
            yield orjson.dumps({
                "model": inference_model_human_id,
                "created_at": datetime.now(tz=timezone.utc),
                "message": {
                    "content": f"!",
                    "role": "assistant",
                },
                "done": False,
            })

        yield orjson.dumps({
            "model": inference_model_human_id,
            "created_at": datetime.now(tz=timezone.utc),
            "message": {
                "content": f"\nInference timeout after {bigsleep_sec} seconds: {inference_model_human_id}",
                "role": "assistant",
            },
            "done": True,
        })

    T = TypeVar('T')

    async def emit_keepalive_chunks(
            primordial: AsyncIterator[str],
            timeout: float | None,
            sentinel: T,
    ) -> AsyncIterator[T]:
        start_time = datetime.now(tz=timezone.utc)
        maybe_next: asyncio.Future[str] | None = None

        try:
            maybe_next = asyncio.ensure_future(primordial.__anext__())
            while True:
                try:
                    yield await asyncio.wait_for(asyncio.shield(maybe_next), timeout)
                    maybe_next = asyncio.ensure_future(primordial.__anext__())
                except asyncio.TimeoutError:
                    current_time = datetime.now(tz=timezone.utc)
                    logger.debug(
                        f"emit_keepalive_chunks(): emitting sentinel type after {current_time - start_time}")
                    yield sentinel

        except StopAsyncIteration:
            pass

        finally:
            if maybe_next is not None:
                maybe_next.cancel()

    # Final chunk for what we're returning
    async for chunk in emit_keepalive_chunks(fake_timeout(), 0.5, None):
        if await is_disconnected():
            logger.debug(f"Somehow detected a client disconnect! (Expected client to just stop iteration)")

        if chunk is None:
            yield orjson.dumps({
                "model": inference_model_human_id,
                "created_at": datetime.now(tz=timezone.utc),
                "message": {
                    # On testing, we don't even need this field, so empty string is fine
                    "content": "",
                    "role": "assistant",
                },
                "done": False,
                # Add random fields, since clients seem robust
                "response": "",
                "status": "Waiting for Ollama response",
            })
            continue

        yield chunk


# TODO: Make sure this doesn't block execution, or whatever.
# TODO: Figure out how to trigger two AsyncIterators at once, but we've already burned a day on it.
async def log_stream_to_console(primordial: AsyncIterator[bytes]) -> AsyncIterator[bytes]:
    """
    TODO: This doesn't work, it only mostly/partly works.
    """
    stored_chunks = []
    buffered_text = ''

    async for chunk0 in primordial:
        yield chunk0
        stored_chunks.append(chunk0)

        chunk0_json = orjson.loads(chunk0)
        if len(buffered_text) >= 120:
            print(buffered_text)
            buffered_text = safe_get(chunk0_json, 'message', 'content') or ""
        else:
            buffered_text += safe_get(chunk0_json, 'message', 'content') or ""

    if buffered_text:
        print(buffered_text)
        del buffered_text

    async def replay_chunks():
        for chunk in stored_chunks:
            yield chunk

    async def to_json(primo: AsyncIterable) -> AsyncIterable[OllamaResponseContentJSON]:
        async for chunk in primo:
            yield orjson.loads(chunk)

    _ = await consolidate_stream(to_json(replay_chunks()))


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
