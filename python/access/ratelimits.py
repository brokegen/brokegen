"""
For potential debugging and caching purposes, offer infrastructure for every network request we make.

Ideally, we would use something like `structlog` or `logging.handlers.HTTPHandler` to send logs elsewhere,
but this will work for the small scale we have (one user, no automation of LLM requests).
"""

import logging
from collections.abc import Callable, Generator
from datetime import datetime, timezone
from typing import TypeAlias, AsyncIterator

import httpx
from sqlalchemy import create_engine, Column, String, DateTime, JSON
from sqlalchemy.orm import declarative_base, sessionmaker, Session

engine = None
SessionLocal: Callable = None
Base = declarative_base()

RatelimitsDB: TypeAlias = Session


def init_db(db_path: str) -> None:
    global engine
    engine = create_engine(
        'sqlite:///' + db_path,
        connect_args={
            "check_same_thread": False,
            "timeout": 1,
        })

    Base.metadata.create_all(bind=engine)

    global SessionLocal
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_db() -> Generator[RatelimitsDB]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


class ApiAccessWithResponse(Base):
    __tablename__ = 'ApiAccessesWithResponse'
    __bind_key__ = 'ratelimits'

    accessed_at = Column(DateTime, primary_key=True, nullable=False)
    api_endpoint = Column(String, primary_key=True, nullable=False)

    api_bucket = Column(String, primary_key=True, nullable=False)
    request = Column(JSON)
    response = Column(JSON)


class PlainRequestInterceptor:
    """
    Wraps an httpx request/response pair, and stores all that content with SQLAlchemy.

    Stores request/response content as the raw bytes that were originally provided,
    which in practice means sometimes the bytes are gzip-encoded or whatever.
    """

    def __init__(
            self,
            logger: logging.Logger,
            ratelimits_db: RatelimitsDB,
    ):
        self.logger = logger
        self.ratelimits_db = ratelimits_db
        self.new_access: ApiAccessWithResponse | None = None

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

    def _response_content_destream(self, *decode_args, **decode_kwargs) -> Generator[str]:
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
    ) -> ApiAccessWithResponse:
        request_dict = {
            'method': upstream_response.request.method,
            'url': str(upstream_response.request.url),
            'content': "[not recorded yet]",
        }
        if upstream_response.request.headers:
            request_dict['headers'] = upstream_response.request.headers.multi_items()

        response_dict = {
            'status_code': upstream_response.status_code,
            'content': "[not recorded yet]",
        }
        if upstream_response.headers:
            response_dict['headers'] = upstream_response.headers.multi_items()
        if upstream_response.cookies:
            response_dict['cookies'] = upstream_response.cookies.jar.items()

        self.new_access = ApiAccessWithResponse(
            api_bucket=api_bucket,
            accessed_at=datetime.now(tz=timezone.utc),
            api_endpoint=str(upstream_response.request.url),
            request=request_dict,
            response=response_dict,
        )

        self.ratelimits_db.add(self.new_access)
        if do_commit:
            self.ratelimits_db.commit()

        return self.new_access

    def update_access_event(
            self,
            do_commit: bool = True,
    ) -> None:
        raise NotImplementedError()
