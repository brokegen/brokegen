import asyncio
import logging
from datetime import datetime, timezone
from typing import TypeAlias, AsyncIterable, AsyncIterator, Any, Callable, Awaitable, Iterator, Iterable

import httpx
import orjson
import sqlalchemy.exc
import starlette.responses
from starlette.background import BackgroundTask
from typing_extensions import deprecated

from audit.http import AuditDB, get_db, HttpEvent
from history.shared.json import JSONDict

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
            if 'response' not in chunk0_json:
                continue

            if buffered_chunks is None:
                buffered_chunks = chunk0_json['response']
            elif len(buffered_chunks) >= min_chunk_length:
                log_fn(buffered_chunks)
                buffered_chunks = chunk0_json['response']
            else:
                buffered_chunks += chunk0_json['response']

        # Eat all exceptions, since this wrapper should be silent and unintrusive.
        except Exception as e:
            log_fn(f"[ERROR] during `chunk_and_log_output`: {e}")
            # Disable the log function, so we don't see more suffering
            log_fn = lambda *args: args

    if buffered_chunks:
        log_fn(buffered_chunks)


@deprecated("Do not use")
class PlainRequestInterceptor:
    """
    Wraps an httpx request/response pair, and stores all that content with SQLAlchemy.

    Stores request/response content as the raw bytes that were originally provided,
    which in practice means sometimes the bytes are gzip-encoded or whatever.
    """

    def __init__(
            self,
            logger: logging.Logger,
            audit_db: AuditDB,
    ):
        self.logger = logger
        self.audit_db = audit_db
        self.new_access: HttpEvent | None = None

        self.request_content_chunks: list[bytes] = []
        self.response_content_chunks: list[bytes] = []

    async def wrap_request_content_raw(self, request_content_stream: AsyncIterator[bytes]):
        async for chunk in request_content_stream:
            yield chunk
            self.request_content_chunks.append(chunk)

    async def wrap_response_content_raw(self, response_content_stream: AsyncIterator[bytes]):
        # TODO: Write this to SQLite every N chunks or bytes or whatever
        async for chunk in response_content_stream:
            yield chunk
            self.response_content_chunks.append(chunk)

    def request_content_as_str(self, *decode_args, **decode_kwargs) -> str | None:
        if not self.request_content_chunks:
            return None

        merged_request_bytes = bytearray(b''.join(self.request_content_chunks))
        if len(merged_request_bytes) <= 0:
            return None

        return merged_request_bytes.decode(*decode_args, **decode_kwargs)

    def _response_content_destream(self, *decode_args, **decode_kwargs):
        if not self.response_content_chunks:
            yield from []
            return

        for chunk in self.response_content_chunks:
            chunk_str = chunk.decode(*decode_args, **decode_kwargs)
            if len(chunk_str) > 0:
                if chunk_str[-1] == '\n':
                    yield chunk_str[:-1]
                else:
                    # This is only an error if the chunk isn't "done", which happens occasionally.
                    # Well, once every request, actually.
                    self.logger.warning(f"Parsed JSON blob that doesn't end in a newline, this isn't newline-delimited")
                    yield chunk_str

    def response_content_as_str(self, *decode_args, **decode_kwargs) -> str | None:
        """
        Return things as an "encoded" array of JSON content
        """
        return (
                '[' +
                ','.join(self._response_content_destream(*decode_args, **decode_kwargs)) +
                ']'
        )

    def build_access_event(
            self,
            upstream_response: httpx.Response,
            api_bucket: str,
            do_commit: bool = True,
    ) -> HttpEvent:
        request_dict = {
            'content': "[not recorded yet/interrupted during processing]",
            'method': upstream_response.request.method,
            'url': str(upstream_response.request.url),
        }
        if upstream_response.request.headers:
            request_dict['headers'] = upstream_response.request.headers.multi_items()

        response_dict = {
            'status_code': upstream_response.status_code,
            'content': "[not recorded yet/interrupted during processing]",
        }
        if upstream_response.headers:
            response_dict['headers'] = upstream_response.headers.multi_items()
        if upstream_response.cookies:
            response_dict['cookies'] = upstream_response.cookies.jar.items()

        self.new_access = HttpEvent(
            api_bucket=api_bucket,
            accessed_at=datetime.now(tz=timezone.utc),
            api_endpoint=str(upstream_response.request.url),
            request=request_dict,
            response=response_dict,
        )

        self.audit_db.add(self.new_access)
        if do_commit:
            self.audit_db.commit()

        return self.new_access

    def update_access_event(
            self,
            do_commit: bool = True,
    ) -> None:
        raise NotImplementedError()


@deprecated("Migrate to OllamaJSONInterceptor")
class JSONRequestInterceptor(PlainRequestInterceptor):
    """
    Tries to decode content bytes as JSON

    (Parent class assumes utf-8 for string operations, which is fine for JSON.)
    """
    response_content_json: list[dict]
    """
    This is a list of JSON-like objects, decoded from a streaming JSON response.

    (Each line of the content is presumed to be valid JSON; we keep it in parsed format,
    because we allow for consolidate() to be called at any time, which would simply
    turn lines into more JSON.)
    """

    def __init__(
            self,
            audit_db: AuditDB | None = None,
    ):
        if audit_db is None:
            audit_db = next(get_db())

        super().__init__(logger, audit_db)

        self.response_content_json = []

    async def wrap_request_content(self, request_content_stream: AsyncIterator[bytes]):
        recorded_content = self.wrap_request_content_raw(request_content_stream)
        async for chunk in recorded_content:
            self.logger.debug(f"Intercepting request chunk: {len(chunk)=} bytes")
            yield chunk

        # Try decoding the entire contents if there's not that much.
        # NB This will break on gzip/brotli/etc encoding.
        if len(self.request_content_chunks) == 1 and len(self.request_content_chunks[0]) < 80:
            self.logger.debug(f"Intercepted request chunk: {self.request_content_as_str()}")

        # Now that we're done, try committing changes to db
        if self.new_access:
            self.new_access = self.audit_db.merge(self.new_access)
            self.audit_db.add(self.new_access)
            self.audit_db.commit()

    async def wrap_response_content(
            self,
            response_content_stream: AsyncIterator[str],
            print_all_response_data: bool = False,
    ):
        async for line in response_content_stream:
            # This gets called while streaming JSON inference, so try to minimize prints + truncate the line
            if print_all_response_data and len(line) > 0:
                self.logger.debug(f"Intercepting response line: {line[:120]}")

            yield line
            self.response_content_json.append(orjson.loads(line))

        # Now that we're done, try committing changes to db
        async def commit_task(delay: float) -> None:
            if delay > 0:
                await asyncio.sleep(delay)

            self.new_access = self.audit_db.merge(self.new_access)
            self.audit_db.add(self.new_access)
            self.audit_db.commit()

        if self.new_access:
            try:
                await commit_task(0)
            except sqlalchemy.exc.OperationalError:
                self.logger.warning(f"Failed to commit content to db, will retry in 60 seconds")
                await asyncio.create_task(commit_task(60))

    async def consolidate_json_response(self):
        if self.response_content_chunks:
            self.logger.warning(f"Called RequestInterceptor.consolidate_json_response(), but we have raw bytes data")

        try:
            # TODO: Hacky way to convert to async; we _probably_ do not need an async consolidation routine,
            #       as any data we'd need or want should be gathered by then.
            async def json_aiter():
                for chunk in self.response_content_json:
                    yield chunk

            consolidated_response = await consolidate_stream(
                json_aiter(),
                self.logger.warning,
            )

            self.response_content_json = [consolidated_response]

        except ValueError:
            self.logger.exception(f"Failed to consolidate response JSON content")

    def request_content_as_json(self) -> dict | None:
        content_as_str = self.request_content_as_str('utf-8')
        if not content_as_str:
            return None

        return orjson.loads(content_as_str)

    def response_content_as_json(self) -> dict | None:
        # First, check if the parent class is hiding anything in self.response_content_chunks
        content_as_str = self.response_content_as_str('utf-8')
        # TODO: The JSON-vs-bytes leaking everywhere is really nasty. Almost like JavaScript.
        if content_as_str != '[]':
            return orjson.loads(content_as_str)

        # Next, check if we need a consolidation
        if len(self.response_content_json) > 1:
            self.logger.info(
                f"RequestInterceptor.response_content_json={len(self.response_content_json)}, expected 1 => call consolidate first")
            return None

        return self.response_content_json[0]

    def _set_or_delete_request_content(self, json_ish):
        """
        We need this to be a separate property because SQLAlchemy JSON columns use a lot of caching.

        Rather than doing things correctly, we make a copy of its dict and then update the entire column.
        TODO: Do things correctly.
        """
        new_request_json = dict(self.new_access.request)
        if json_ish:
            new_request_json['content'] = json_ish
        else:
            if 'content' in new_request_json:
                del new_request_json['content']

        self.new_access.request = new_request_json

    def _set_or_delete_response_content(self, json_ish):
        new_response_json = dict(self.new_access.response)
        if json_ish:
            # Remove that Ollama vector chunk that pseudo-embeds history
            if 'context' in json_ish:
                del json_ish['context']

            new_response_json['content'] = json_ish
        else:
            if 'content' in new_response_json:
                del new_response_json['content']

        self.new_access.response = new_response_json

    def update_access_event(
            self,
            do_commit: bool = True,
    ) -> None:
        # By this point, the request is almost always done, and we're running in an unrelated BackgroundTask.
        # `self.new_access` has probably also been committed to db already, but that shouldn't invalidate its contents…
        self.new_access = self.audit_db.merge(self.new_access)

        self._set_or_delete_request_content(self.request_content_as_json())
        self._set_or_delete_response_content(self.response_content_as_json())

        self.audit_db.add(self.new_access)
        if do_commit:
            self.audit_db.commit()


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

    async def wrap_entire_response(
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
                enable_logging: bool = True,
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
            content=_wrapper(upstream_response.aiter_raw()),
            status_code=upstream_response.status_code,
            headers=upstream_response.headers,
            background=BackgroundTask(post_forward_cleanup)
        )

    def _try_commit(self):
        try:
            self.audit_db.add(self.wrapped_event)
            self.audit_db.commit()
        except sqlalchemy.exc.SQLAlchemyError:
            logger.exception(f"Failed to commit request JSON for {self.wrapped_event.api_bucket}")
            self.audit_db.rollback()
