import asyncio
import logging
from datetime import datetime, timezone
from typing import TypeAlias, AsyncIterable, AsyncIterator, Any, Callable, Awaitable, Iterable

import httpx
import orjson
import sqlalchemy.exc
import starlette.responses
from starlette.background import BackgroundTask

from _util.json import JSONDict, safe_get
from audit.http import AuditDB, get_db, HttpEvent

OllamaRequestContentJSON: TypeAlias = JSONDict
OllamaResponseContentJSON: TypeAlias = JSONDict

logger = logging.getLogger(__name__)


async def consolidate_stream(
        primordial: AsyncIterable[OllamaResponseContentJSON],
        override_warn_fn=logger.warning,
) -> OllamaResponseContentJSON:
    """
    Code is mostly specific to streaming Ollama responses,
    but useful enough we can use it in several places.
    """
    consolidated_response: OllamaResponseContentJSON | None = None

    async for decoded_line in primordial:
        if consolidated_response is None:
            # We have to do a dict copy because the old dict can uhh disappear, for some reason.
            # (Usually it's an SQLAlchemy JSON column, which does under-the-hood optimizations.)
            consolidated_response = dict(decoded_line)
            continue

        for k, v in decoded_line.items():
            if k not in consolidated_response:
                consolidated_response[k] = v
                continue

            if k == 'created_at':
                consolidated_response['terminal_created_at'] = v
                continue

            elif k == 'done':
                if consolidated_response[k]:
                    override_warn_fn(f"Received additional JSON after streaming indicated we were {k}={v}")

            elif k == 'model':
                if consolidated_response[k] != v:
                    raise ValueError(
                        f"Received new model name \"{v}\" during streaming response, expected {consolidated_response[k]}")

            # This tends to be the output from /api/generate
            elif k == 'response':
                consolidated_response[k] += v
                continue

            # And this is /api/chat, which we don't care too much about.
            # Except as a stopgap, for now.
            elif k == 'message':
                if set(v.keys()) != {'content', 'role'}:
                    override_warn_fn(f"Received unexpected message content with keys: {v.keys()}")
                if v['role'] != 'assistant':
                    override_warn_fn(f"Received content for unexpected role \"{v['role']}\", continuing anyway")

                consolidated_response[k]['content'] += v['content']
                continue

            else:
                raise ValueError(
                    f"Received unidentified JSON pair {k}={v}, abandoning consolidation of JSON blobs.\n"
                    f"Current consolidated response has key set: {consolidated_response.keys()}")

            # In the non-exceptional case, just update with the new value.
            consolidated_response[k] = v

    done = safe_get(consolidated_response, 'done')
    if not done:
        if done is None:
            logger.debug(f"Ollama response is {done=}, are you sure this was a streaming request?")
        else:
            logger.warning(f"Ollama response is {done=}, but we already ran out of bytes to process")

    if 'context' in consolidated_response:
        del consolidated_response['context']

    return consolidated_response


async def chunk_and_log_output(
        primordial: AsyncIterable[bytes | str],
        log_fn: Callable[[str], Any],
        min_chunk_length: int = 120,
) -> AsyncIterable[bytes | str]:
    buffered_chunks = ''

    async for chunk0 in primordial:
        yield chunk0

        # NB This is very wasteful re-decoding, but don't prematurely optimize.
        try:
            chunk0_json = orjson.loads(chunk0)

            # /api/generate returns in the first form
            # /api/chat returns the second form, with 'role': 'user'
            message_only = safe_get(chunk0_json, 'response') \
                           or safe_get(chunk0_json, 'message', 'content')
            if not message_only:
                continue

            if buffered_chunks is None:
                buffered_chunks = message_only
            elif len(buffered_chunks) >= min_chunk_length:
                log_fn(buffered_chunks)
                buffered_chunks = message_only
            else:
                buffered_chunks += message_only

        # Eat all exceptions, since this wrapper should be silent and unintrusive.
        except Exception as e:
            log_fn(f"[ERROR] during `chunk_and_log_output`: {e}")
            # Disable the log function, so we don't see more suffering
            log_fn = lambda *args: args

    if buffered_chunks:
        log_fn(buffered_chunks)


class OllamaEventBuilder:
    wrapped_event: HttpEvent
    audit_db: AuditDB

    response_content_json: JSONDict | None

    def __init__(
            self,
            api_bucket: str,
            audit_db: AuditDB | None = None,
    ):
        self.wrapped_event = HttpEvent(
            api_bucket=api_bucket,
            accessed_at=datetime.now(tz=timezone.utc),
        )
        self.audit_db = audit_db or next(get_db())

        self.response_content_json = None

    async def wrap_req(
            self,
            primordial: AsyncIterator[bytes],
    ) -> AsyncIterator[bytes]:
        """
        TODO: On unexpected client disconnect, an error is thrown somewhere here.
        Catch the `starlette.requests.ClientDisconnect` in the caller.
        """
        all_chunks = []
        async for chunk0 in primordial:
            yield chunk0
            all_chunks.append(chunk0)

        joined_chunks = b''.join(all_chunks)
        if joined_chunks:
            request_json = orjson.loads(joined_chunks)
            self.wrapped_event.request_info = request_json

        # Do a preliminary commit, because partial info is what we'd need for debugging
        self._try_commit()

    async def wrap_response(
            self,
            upstream_response: httpx.Response,
            *on_done_fns: Callable[[OllamaResponseContentJSON], Awaitable[Any]],
    ) -> starlette.responses.Response:
        content = upstream_response.content
        self.response_content_json = orjson.loads(content)
        self.wrapped_event.response_content = self.response_content_json
        self._try_commit()

        async def post_forward_cleanup():
            for on_done_fn in on_done_fns:
                if on_done_fn is not None:
                    try:
                        await on_done_fn(self.response_content_json or {})
                    except RuntimeError:
                        logger.exception(f"Failed to complete post_forward_cleanup(): {on_done_fn}")
                        continue

        return starlette.responses.Response(
            content=content,
            status_code=upstream_response.status_code,
            headers=upstream_response.headers,
            background=BackgroundTask(post_forward_cleanup),
        )

    async def wrap_entire_streaming_response(
            self,
            upstream_response: httpx.Response,
            *on_done_fns: Callable[[OllamaResponseContentJSON], Awaitable[Any]],
    ) -> starlette.responses.StreamingResponse:
        async def reconsolidate(chunks: Iterable[bytes | str]):
            done_marker = object()
            it = iter(chunks)

            while (value := await asyncio.to_thread(next, it, done_marker)) is not done_marker:
                yield orjson.loads(value)

        async def _wrapper(
                primordial: AsyncIterator[bytes | str],
                enable_logging: bool = False,
        ) -> AsyncIterator[bytes | str]:
            primordial1 = primordial
            if enable_logging:
                primordial1 = chunk_and_log_output(primordial, print)

            all_chunks = []
            async for chunk0 in primordial1:
                yield chunk0
                all_chunks.append(chunk0)

            self.response_content_json = await consolidate_stream(reconsolidate(all_chunks))
            if upstream_response.is_success and self.response_content_json:
                self.wrapped_event.response_content = self.response_content_json
                self._try_commit()
            else:
                self.wrapped_event.response_content = {
                    "status_code": upstream_response.status_code,
                    "headers": upstream_response.headers,
                }
                self._try_commit()

        async def post_forward_cleanup():
            await upstream_response.aclose()
            self._try_commit()

            for on_done_fn in on_done_fns:
                if on_done_fn is not None:
                    await on_done_fn(self.response_content_json or {})

        return starlette.responses.StreamingResponse(
            content=_wrapper(upstream_response.aiter_bytes()),
            status_code=upstream_response.status_code,
            headers=upstream_response.headers,
            background=BackgroundTask(post_forward_cleanup),
        )

    def _try_commit(self):
        try:
            self.audit_db.add(self.wrapped_event)
            self.audit_db.commit()
        except sqlalchemy.exc.SQLAlchemyError:
            logger.exception(f"Failed to commit request JSON for {self.wrapped_event.api_bucket}")
            self.audit_db.rollback()
