"""
For potential debugging and caching purposes, offer infrastructure for every network request we make.

Ideally, we would use something like `structlog` or `logging.handlers.HTTPHandler` to send logs elsewhere,
but this will work for the small scale we have (one user, no automation of LLM requests).
"""
try:
    import orjson as json
except ImportError:
    import json

import logging
from collections.abc import Callable, Generator
from datetime import datetime, timezone
from typing import TypeAlias, AsyncIterator

import httpx
from sqlalchemy import create_engine, Column, String, DateTime, JSON
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session

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


class RequestInterceptor:
    """
    Wraps an httpx request/response pair, and stores all that content with SQLAlchemy.
    """

    def __init__(self, logger: logging.Logger, ratelimits_db: RatelimitsDB):
        self.logger = logger
        self.ratelimits_db = ratelimits_db
        self.new_access: ApiAccessWithResponse | None = None

        self.request_content: bytearray = bytearray()

        self.response_content_bytes: bytearray = bytearray()
        self.response_content: list = []

    async def wrap_request_content(self, request_content_stream: AsyncIterator[bytes]):
        async for chunk in request_content_stream:
            if len(chunk) > 0:
                self.logger.debug(f"Intercepting request chunk: {len(chunk)=} bytes")

            yield chunk
            self.request_content.extend(chunk)

    async def consolidate_response_content(self, response: httpx.Response):
        """
        Decodes the response into text lines, and then consolidates the streaming JSON into one JSON blob.
        """
        raise NotImplementedError()

    async def wrap_response_content(
            self,
            response: httpx.Response,
            disable_json_decode: bool = False,
    ):
        async for line in response.aiter_lines():
            if len(line) > 0:
                self.logger.debug(f"Intercepting response line: {line[:120]}")

            yield line
            if disable_json_decode:
                self.response_content.append(line)
            else:
                decoded_line: dict = json.loads(line)
                self.response_content.append(decoded_line)

    async def wrap_response_content_raw(self, response: httpx.Response):
        """
        Don't do any decoding (of gzip, or brotli, or any other HTTP-level compression/encoding

        Mostly useful for direct streaming, with low overhead. Which we don't need yet.
        """
        async for chunk in response.aiter_raw():
            if len(chunk) > 0:
                self.logger.debug(f"Intercepting encoded response chunk: {len(chunk)=} bytes")

            yield chunk
            self.response_content_bytes.extend(chunk)

        # Wait for the entire response to be forwarded before erroring out
        raise NotImplementedError()

    def generate_api_access(
            self,
            upstream_response: httpx.Response,
            api_bucket: str,
            do_commit: bool = True,
    ):
        self.new_access = ApiAccessWithResponse(
            api_bucket=api_bucket,
            accessed_at=datetime.now(tz=timezone.utc),
            api_endpoint=str(upstream_response.request.url),
            request={
                'method': upstream_response.request.method,
                'url': str(upstream_response.request.url),
                'headers': upstream_response.request.headers.multi_items().sort(),
                'content': "[not recorded yet]",
            },
            response={
                'status_code': upstream_response.status_code,
                'headers': upstream_response.headers.multi_items().sort(),
                'content': "[not recorded yet]",
            },
        )

        self.ratelimits_db.add(self.new_access)
        if do_commit:
            self.ratelimits_db.commit()
            # TODO: How important is this to keep around? Will `ratelimits_db.merge()` obviate it?
            self.ratelimits_db.refresh(self.new_access)

        return self.new_access

    def _consolidate_content(self):
        if not self.response_content:
            return

        consolidated_response = None
        for next_response in self.response_content:
            if consolidated_response is None:
                # We have to do a dict copy because the old ones uhh disappear, for some reason.
                consolidated_response = dict(next_response)
                continue

            for k, v in next_response.items():
                if k not in consolidated_response:
                    consolidated_response[k] = v
                    continue

                if k == 'created_at':
                    consolidated_response['terminal_created_at'] = v
                    continue

                elif k == 'done':
                    if consolidated_response[k]:
                        self.logger.warning(f"Received additional JSON after streaming indicated we were {k}={v}")

                elif k == 'model':
                    if consolidated_response[k] != v:
                        self.logger.error(
                            f"Received new model name \"{v}\" during streaming response, expected {consolidated_response[k]}")
                        return

                elif k == 'response':
                    consolidated_response[k] += v
                    continue

                else:
                    self.logger.error(f"Received unidentified JSON pair, {k}={v}")
                    return

                # In the non-exceptional case, just update with the new value.
                consolidated_response[k] = v

        self.response_content = [consolidated_response]

    def update_api_access_content(
            self,
            do_commit: bool = True,
            decode_request_as_json: bool = True,
    ):
        """
        Intended to be called during cleanup, so we can update the DB with content we're done streaming

        TODO: We assume the request/response content is UTF8-encoded;
              for correctness we should read the encoding from HTTP headers.
        """
        merged_access = self.ratelimits_db.merge(self.new_access)

        if self.request_content:
            if decode_request_as_json:
                merged_access.request['content'] = json.loads(self.request_content)
            else:
                merged_access.request['content'] = self.request_content.decode('utf-8')
        else:
            del merged_access.request['content']

        if self.response_content_bytes:
            merged_access.response['content'] = self.response_content_bytes.decode('utf-8')
        elif self.response_content:
            merged_access.response['content'] = self.response_content
        else:
            del merged_access.response['content']

        self.ratelimits_db.add(merged_access)
        if do_commit:
            self.ratelimits_db.commit()
