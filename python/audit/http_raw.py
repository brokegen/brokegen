"""
For potential debugging and caching purposes, offer infrastructure for every network request we make.

Ideally, we would use something like `structlog` or `logging.handlers.HTTPHandler` to send logs elsewhere,
but this will work for the small scale we have (one user, no automation of LLM requests).
"""
from typing import AsyncIterable, Sequence

from fastapi import FastAPI
from sqlalchemy import Column, String, DateTime, JSON, LargeBinary, Integer, inspect
from sqlalchemy.orm import AttributeState
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import StreamingResponse

from audit.http import Base, AuditDB


class RawHttpEvent(Base):
    __tablename__ = 'RawHttpEvents'
    __bind_key__ = 'access'

    accessed_at = Column(DateTime, primary_key=True, nullable=False)
    request_url = Column(String, primary_key=True, nullable=False)
    request_method = Column(String, nullable=False)
    request_headers = Column(JSON)
    request_cookies = Column(JSON)
    request_content = Column(LargeBinary)

    response_status_code = Column(Integer)
    response_raw_headers = Column(JSON)
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

    async def wrap_response_content_stream(
            self,
            primordial: AsyncIterable[str | bytes],
    ) -> AsyncIterable[str | bytes]:
        self.response_content = b''
        async for chunk0 in primordial:
            yield chunk0
            self.response_content += chunk0
            # Add a newline to delineate the data, since all JSON (NDJSON) content should have escaped newlines anyway
            self.response_content += b'\n'

        print(self)


class SqlLoggingMiddleware(BaseHTTPMiddleware):
    def __init__(self, app: FastAPI, audit_db: AuditDB):
        super().__init__(app)
        self.audit_db = audit_db

    async def dispatch(
            self,
            request,
            call_next,
    ):
        event = RawHttpEvent()
        # Query params are expected to remain encoded here
        event.request_url = request.url
        event.request_method = request.method
        event.request_headers = request.headers
        event.request_cookies = request.cookies

        # NB This is fine because Starlette calls Middleware with starlette.middleware.base._CachedRequest,
        #    so we can't actually modify the Request that gets sent out.
        event.request_content = await request.body()

        response = await call_next(request)
        event.response_status_code = response.status_code
        event.response_raw_headers = response.raw_headers

        event.response_content = b"[not read yet]"
        if isinstance(response, StreamingResponse):
            response.body_iterator = \
                event.wrap_response_content_stream(response.body_iterator)
        else:
            event.response_content = response.body()

        return response
