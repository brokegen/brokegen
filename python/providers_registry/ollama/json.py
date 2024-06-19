import logging
from datetime import datetime, timezone
from typing import AsyncIterable, AsyncIterator, Any, Callable, Awaitable, AsyncGenerator

import httpx
import orjson
import sqlalchemy.exc
import starlette.responses
from starlette.background import BackgroundTask

from _util.json import JSONDict, safe_get
from _util.json_streaming import JSONStreamingResponse, emit_keepalive_chunks
from _util.status import ServerStatusHolder
from _util.typing import InferenceModelHumanID
from audit.content_scrubber import scrub_json
from audit.http import AuditDB, get_db, HttpEvent
from inference.iterators import stream_bytes_to_json, tee_to_console_output, dump_to_bytes, consolidate_and_call
from .api_chat.logging import ollama_log_indexer, ollama_response_consolidator, OllamaResponseContentJSON

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


async def keepalive_wrapper(
        inference_model_human_id: InferenceModelHumanID,
        real_response_maker: Awaitable[JSONStreamingResponse],
        status_holder: ServerStatusHolder,
        allow_non_ollama_fields: bool = False,
) -> JSONStreamingResponse:
    async def nonblocking_response_maker():
        async for item in (await real_response_maker).body_iterator:
            yield item

    async def do_keepalive(
            primordial: AsyncIterator[str | bytes],
    ) -> AsyncGenerator[str | bytes, None]:
        """
        Screen timeout for an iOS device with FaceID is 30 seconds (which maps to network timeout for simple iOS apps),
        so set the keepalive to be a fraction of that.

        NB during things like RAG loading, we want updates more frequently than 9.5 seconds.
        """
        async for chunk in emit_keepalive_chunks(primordial, 3.0, None):
            if chunk is None:
                constructed_chunk = {
                    "model": inference_model_human_id,
                    "created_at": datetime.now(tz=timezone.utc).isoformat() + "Z",
                    "done": False,
                    "message": {
                        # After testing, it turns out we don't even need this field, so empty string is fine
                        "content": "",
                        "role": "assistant",
                    },
                }
                if allow_non_ollama_fields:
                    # Add random fields if clients seem robust (they're usually not).
                    constructed_chunk["response"] = ""
                    constructed_chunk["status"] = status_holder.get()

                yield orjson.dumps(constructed_chunk)
                continue

            yield chunk

    return JSONStreamingResponse(
        content=do_keepalive(nonblocking_response_maker()),
        status_code=218,
    )


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

    def wrap_request(
            self,
            request_content: JSONDict,
            remove_images: bool = True,
    ):
        if remove_images:
            scrubbed_request_content = scrub_json(
                request_content.copy(),
                logger.warning,
                remove_images,
            )
            self.wrapped_event.request_info = scrubbed_request_content

        else:
            self.wrapped_event.request_info = request_content

        return request_content

    async def wrap_streaming_request(
            self,
            primordial: AsyncIterator[bytes],
            remove_images: bool = True,
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

            if remove_images:
                maybe_content = scrub_json(request_json, logger.warning, remove_images)
                self.wrapped_event.request_info = maybe_content

        # Do a preliminary commit, because partial info is what we'd need for debugging
        self._try_commit()

    async def wrap_response(
            self,
            upstream_response: httpx.Response,
            *on_done_fns: Callable[[OllamaResponseContentJSON], Awaitable[Any]],
    ) -> starlette.responses.Response:
        content = upstream_response.content
        if upstream_response.is_success and content:
            try:
                self.response_content_json = orjson.loads(content)
                self.wrapped_event.response_content = self.response_content_json
                self._try_commit()
            except Exception as e:
                logger.error(f"Failed to parse response content, forwarding response to client anyway: {e}")
        else:
            self.wrapped_event.response_info = {
                "status_code": upstream_response.status_code,
                "reason_phrase": upstream_response.reason_phrase,
                "content": content.decode(),
                "headers": dict(upstream_response.headers),
                "http_version": upstream_response.http_version,
            }
            self._try_commit()

        async def post_forward_cleanup():
            await upstream_response.aclose()

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
            enable_logging: bool = False,
            *on_done_fns: Callable[[OllamaResponseContentJSON], Awaitable[Any]],
    ) -> starlette.responses.StreamingResponse:
        async def response_recorder(
                consolidated_response: OllamaResponseContentJSON,
        ) -> None:
            if upstream_response.is_success and self.response_content_json:
                self.wrapped_event.response_content = self.response_content_json
            else:
                self.wrapped_event.response_content = {
                    "status_code": upstream_response.status_code,
                    "reason_phrase": upstream_response.reason_phrase,
                    # NB This is explicitly kept as strings and not JSON objects
                    # because scanning strings is easier.
                    "content": orjson.dumps(consolidated_response).decode(),
                    "headers": dict(upstream_response.headers),
                    "http_version": upstream_response.http_version,
                }

            self._try_commit()
            self.response_content_json = consolidated_response

        async def post_forward_cleanup():
            await upstream_response.aclose()
            self._try_commit()

            for on_done_fn in on_done_fns:
                if on_done_fn is not None:
                    logger.debug(f"Calling {on_done_fn=}")
                    await on_done_fn(self.response_content_json or {})

        iter0: AsyncIterator[bytes] = upstream_response.aiter_bytes()
        iter1: AsyncIterator[JSONDict] = stream_bytes_to_json(iter0)
        if enable_logging:
            iter2: AsyncIterator[JSONDict] = tee_to_console_output(iter1, ollama_log_indexer)
        else:
            iter2 = iter1

        iter3: AsyncIterator[JSONDict] = consolidate_and_call(
            iter2, ollama_response_consolidator, {},
            response_recorder,
        )
        iter4: AsyncIterator[bytes] = dump_to_bytes(iter3)

        return starlette.responses.StreamingResponse(
            content=iter4,
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
