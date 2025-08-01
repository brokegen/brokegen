"""
For potential debugging and caching purposes, offer infrastructure for every network request we make.

Ideally, we would use something like `structlog` or `logging.handlers.HTTPHandler` to send logs elsewhere,
but this will work for the small scale we have (one user, no automation of LLM requests).
"""
import logging
import sys
import traceback
from datetime import timezone, datetime
from typing import AsyncIterable, Sequence, AsyncIterator

import httpx
import sqlalchemy.exc
from fastapi import FastAPI
from sqlalchemy import Column, String, DateTime, JSON, LargeBinary, Integer, inspect
from sqlalchemy.orm import AttributeState
from starlette.middleware.base import BaseHTTPMiddleware, _StreamingResponse
from starlette.responses import StreamingResponse

from audit.content_scrubber import scrub_bytes
from audit.http import Base, AuditDB

logger = logging.getLogger(__name__)


class RawHttpEvent(Base):
    __tablename__ = 'RawHttpEvents'
    __bind_key__ = 'access'

    id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)

    accessed_at = Column(DateTime, nullable=False)
    request_url = Column(String, nullable=False)
    request_method = Column(String, nullable=False)
    request_headers = Column(JSON)
    request_cookies = Column(JSON)
    request_content = Column(LargeBinary)

    response_status_code = Column(Integer)
    response_headers = Column(JSON)
    response_content = Column(LargeBinary)
    """
    This is generally expected to be NDJSON, streamed from the server.

    Ideally we have timestamps tied to the chunks streamed out.
    """

    def dump_as_str(self, max_value_length: int | None = 120):
        state = inspect(self)

        attribute: AttributeState
        for attribute in state.attrs:
            if (
                    max_value_length is not None
                    and isinstance(attribute.value, Sequence)
                    and len(attribute.value) > max_value_length
            ):
                yield f"{attribute.key}: {attribute.value[:max_value_length]}…"
            else:
                yield f"{attribute.key}: {attribute.value}"

    def __str__(self):
        return "\n".join(self.dump_as_str())

    def _try_commit(self, audit_db: AuditDB | None) -> None:
        if audit_db is None:
            return

        try:
            audit_db.add(self)
            audit_db.commit()
        except sqlalchemy.exc.SQLAlchemyError:
            logger.exception(f"Failed to commit StreamingResponse, {len(self.response_content)=}")
            audit_db.rollback()

    async def wrap_response_content_stream(
            self,
            primordial: AsyncIterable[str | bytes],
            audit_db: AuditDB | None,
            commit_cadence: int = 4_096,
    ) -> AsyncIterable[str | bytes]:
        self.response_content = b''
        last_commit_size = -1

        async for chunk0 in primordial:
            yield chunk0
            self.response_content += chunk0
            # Add a newline to delineate the data, since all JSON (NDJSON) content should have escaped newlines anyway
            self.response_content += b'\n'

            if len(self.response_content) - last_commit_size > commit_cadence:
                self._try_commit(audit_db)

        self._try_commit(audit_db)


class SqlLoggingMiddleware(BaseHTTPMiddleware):
    def __init__(self, app: FastAPI, audit_db: AuditDB):
        super().__init__(app)
        self.audit_db = audit_db

    async def dispatch(
            self,
            request,
            call_next,
            remove_images: bool = True,
    ):
        event = RawHttpEvent()
        # Query params are expected to remain encoded here
        event.accessed_at = datetime.now(tz=timezone.utc)
        event.request_url = str(request.url)
        event.request_method = request.method
        event.request_headers = request.headers.items()
        event.request_cookies = request.cookies

        # NB This is fine because Starlette calls Middleware with starlette.middleware.base._CachedRequest,
        #    so we can't actually modify the Request that gets sent out.
        event.request_content = await request.body()

        maybe_content = await scrub_bytes(event.request_content, logger.warning, remove_images)
        if maybe_content is not None:
            event.request_content = maybe_content

        response = await call_next(request)
        event.response_status_code = response.status_code
        event.response_headers = response.headers.items()

        event.response_content = b"[not read yet]"
        if isinstance(response, StreamingResponse) or isinstance(response, _StreamingResponse):
            response.body_iterator = \
                event.wrap_response_content_stream(response.body_iterator, self.audit_db)
        else:
            event.response_content = response.body()
            try:
                self.audit_db.add(event)
                self.audit_db.commit()
            except sqlalchemy.exc.SQLAlchemyError:
                logger.exception("Failed to commit non-StreamingResponse HTTP response")
                self.audit_db.rollback()

        return response


class HttpxLogger:
    def __init__(
            self,
            client: httpx.AsyncClient,
            audit_db: AuditDB,
    ):
        self.client = client
        self.audit_db = audit_db

        self.event = RawHttpEvent()

    async def request_logger(self, request: httpx.Request, remove_images: bool = True):
        # Stay bound to a session
        if sqlalchemy.inspect(self.event).detached:
            logger.debug(f"RawHttpEvent seems detached, merging back into audit_db")
            traceback.print_stack(file=sys.stdout)
            self.event = self.audit_db.merge(self.event)

        self.event.accessed_at = datetime.now(tz=timezone.utc)
        self.event.request_url = str(request.url)
        self.event.request_method = request.method
        self.event.request_headers = dict(request.headers.items())
        self.event.request_cookies = None

        # TODO: This will be a very long, slow call. Is it worth reading _here_?
        self.event.request_content = await request.aread()

        maybe_content = await scrub_bytes(self.event.request_content, logger.warning, remove_images)
        if maybe_content is not None:
            self.event.request_content = maybe_content

        # Write the content right back to the request. No longer streaming, but we couldn't afford that anyway.
        request._content = self.event.request_content

    async def response_logger(self, response: httpx.Response):
        self.event.response_status_code = response.status_code
        self.event.response_headers = dict(response.headers.items())

        async def post_response_wrapper(
                joined_chunks: bytes,
        ):
            # DEBUG: This _works_, but it's very redundant.
            # Originally added because the call below would show that the Session had expired.
            merged = self.audit_db.merge(self.event)
            merged.response_content = joined_chunks

            try:
                self.audit_db.add(merged)
                self.audit_db.commit()
            except sqlalchemy.exc.SQLAlchemyError:
                logger.exception("Failed to commit intercepted httpx traffic")
                self.audit_db.rollback()

            self.event = merged

        async def response_wrapper(
                primordial: AsyncIterator[bytes],
                commit_cadence: int = 5,
        ) -> AsyncIterator[bytes]:
            all_chunks = []

            async for chunk0 in primordial:
                yield chunk0
                all_chunks.append(chunk0)

                if len(all_chunks) % commit_cadence == 0:
                    await post_response_wrapper(b''.join(all_chunks))

            await post_response_wrapper(b''.join(all_chunks))

            # True ending: restore the event hooks.
            self.client.event_hooks = self.original_event_hooks

        # This reaches in to monkeypatch internals, and assumes no callers will call aiter_raw()
        # TODO: Check if any of _our_ callers hit up aiter_raw()
        response.original_aiter_bytes = response.aiter_bytes
        response.aiter_bytes = lambda: response_wrapper(response.original_aiter_bytes())

        # This is only the first capture; further/final capture is at the end of response_wrapper()
        await post_response_wrapper(b'')

    def __enter__(self):
        async def req_fn(request: httpx.Request):
            return await self.request_logger(request)

        async def resp_fn(response: httpx.Response):
            return await self.response_logger(response)

        self.original_event_hooks = self.client.event_hooks
        self.client.event_hooks = {
            'request': [req_fn],
            'response': [resp_fn],
        }

    def __exit__(self, exc_type, exc_val, exc_tb):
        # This should reset the event hooks, but what we really want is to reset them after the capture is done.
        # self.client.event_hooks = self.original_event_hooks
        pass
