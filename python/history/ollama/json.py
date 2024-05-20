import asyncio
import logging
from typing import TypeAlias, AsyncIterable, AsyncIterator, Iterable, Dict, AnyStr, Any, List, Callable

import orjson
import sqlalchemy.exc
import starlette.datastructures
from starlette.background import BackgroundTask
from starlette.concurrency import iterate_in_threadpool
from starlette.responses import StreamingResponse, JSONResponse

from access.ratelimits import PlainRequestInterceptor, RatelimitsDB, get_db

# These aren't strictly defined recursive because they're recursive
# (can contain themselves/each other/JSONValue).
JSONObject: TypeAlias = Any

JSONDictKey: TypeAlias = AnyStr
JSONDict: TypeAlias = Dict[JSONDictKey, JSONObject]
JSONArray: TypeAlias = List[JSONObject]

OllamaRequestContentJSON: TypeAlias = JSONDict
OllamaResponseContentJSON: TypeAlias = JSONDict

logger = logging.getLogger(__name__)


async def consolidate_stream(
        primordial: AsyncIterable[OllamaResponseContentJSON],
        override_warn_fn = logger.warning,
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
        primordial: AsyncIterable[bytes],
        log_fn: Callable[[str], Any],
        min_chunk_length: int = 120,
) -> AsyncIterable[bytes]:
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
            logger: logging.Logger,
            ratelimits_db: RatelimitsDB | None = None,
    ):
        if ratelimits_db is None:
            ratelimits_db = next(get_db())

        super().__init__(logger, ratelimits_db)

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
            self.new_access = self.ratelimits_db.merge(self.new_access)
            self.ratelimits_db.add(self.new_access)
            self.ratelimits_db.commit()

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

            self.new_access = self.ratelimits_db.merge(self.new_access)
            self.ratelimits_db.add(self.new_access)
            self.ratelimits_db.commit()

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
        self.new_access = self.ratelimits_db.merge(self.new_access)

        self._set_or_delete_request_content(self.request_content_as_json())
        self._set_or_delete_response_content(self.response_content_as_json())

        self.ratelimits_db.add(self.new_access)
        if do_commit:
            self.ratelimits_db.commit()


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


def safe_get(
        parent_json_ish: JSONDict | JSONArray | None,
        *keys: JSONDictKey,
) -> JSONObject | None:
    """
    Returns None if any of the intermediate keys failed to appear.

    Only handles dicts, no lists.
    """
    if not parent_json_ish:
        return None

    next_json_ish = parent_json_ish
    for key in keys:
        if key in next_json_ish:
            next_json_ish = next_json_ish[key]
        else:
            return None

    return next_json_ish
