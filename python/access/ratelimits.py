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


class RequestInterceptor:
    """
    Wraps an httpx request/response pair, and stores all that content with SQLAlchemy.
    """

    def __init__(
            self,
            logger: logging.Logger,
            ratelimits_db: RatelimitsDB | None = None,
    ):
        self.logger = logger
        self.ratelimits_db = ratelimits_db
        if not ratelimits_db:
            self.ratelimits_db = next(get_db())
        self.new_access: ApiAccessWithResponse | None = None

        self.request_content: list[bytes] = []

        self.response_content_bytes: list[bytes] = []
        self.response_content: list = []

    async def wrap_request_content(self, request_content_stream: AsyncIterator[bytes]):
        async for chunk in request_content_stream:
            if len(chunk) > 0:
                # TODO: Save up the list of messages, if we really need to.
                self.logger.debug(f"Intercepting request chunk: {len(chunk)=} bytes")

            yield chunk
            self.request_content.append(chunk)

        # Try decoding the entire contents if there's not that much.
        # NB This will break on gzip/brotli/etc encoding.
        if len(self.request_content) == 1 and len(self.request_content[0]) < 80:
            self.logger.debug(f"Intercepted request chunk: {self.request_content[0].decode('utf-8')}")

    async def wrap_response_content(
            self,
            response_lines: AsyncIterator[str],
            print_all_response_data: bool = False,
            disable_json_decode: bool = False,
    ):
        async for line in response_lines:
            if print_all_response_data and len(line) > 0:
                self.logger.debug(f"Intercepting response line: {line[:120]}")

            yield line
            if disable_json_decode:
                self.response_content.append(line)
            else:
                decoded_line: dict = json.loads(line)
                self.response_content.append(decoded_line)

    async def wrap_response_content_raw(self, response_bytes: AsyncIterator[bytes]):
        """
        Don't do any decoding (of gzip, or brotli, or any other HTTP-level compression/encoding

        Mostly useful for direct streaming, with low overhead. Which we don't need yet.
        """
        async for chunk in response_bytes:
            if len(chunk) > 0:
                self.logger.debug(f"Intercepting encoded response chunk: {len(chunk)=} bytes")

            yield chunk
            self.response_content_bytes.append(chunk)

        # Wait for the entire response to be forwarded before erroring out
        raise NotImplementedError()

    def generate_api_access(
            self,
            upstream_response: httpx.Response,
            api_bucket: str,
            do_commit: bool = True,
    ):
        request_dict = {
            'method': upstream_response.request.method,
            'url': str(upstream_response.request.url),
        }
        if upstream_response.request.headers:
            request_dict['headers'] = upstream_response.request.headers.multi_items().sort()

        response_dict = {
            'status_code': upstream_response.status_code,
            'content': "[not recorded yet]",
        }
        if upstream_response.headers:
            response_dict['headers'] = upstream_response.headers.multi_items().sort()
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
            # TODO: How important is this to keep around? Will `ratelimits_db.merge()` obviate it?
            self.ratelimits_db.refresh(self.new_access)

        return self.new_access

    def _consolidate_content(self):
        if not self.response_content:
            return

        consolidated_response = None
        for next_response in self.response_content:
            if type(next_response) is not dict:
                self.logger.info(f"Cannot decode stored responses as JSON, skipping")
                return

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
            merged_request_bytes = bytearray(b''.join(self.request_content))
            if len(merged_request_bytes) > 0:
                if decode_request_as_json:
                    merged_access.request['content'] = json.loads(merged_request_bytes)
                else:
                    merged_access.request['content'] = merged_request_bytes.decode('utf-8')
        else:
            del merged_access.request['content']

        if self.response_content_bytes:
            merged_response_bytes = bytearray(b''.join(self.response_content_bytes))
            merged_access.response['content'] = merged_response_bytes.decode('utf-8')
        elif self.response_content:
            merged_access.response['content'] = self.response_content
        else:
            del merged_access.response['content']

        self.ratelimits_db.add(merged_access)
        if do_commit:
            self.ratelimits_db.commit()
