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
import orjson
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


class RequestInterceptor(PlainRequestInterceptor):
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

    def consolidate_json_response(self):
        if self.response_content_chunks:
            self.logger.warning(f"Called RequestInterceptor.consolidate_json_response(), but we have raw bytes data")

        if not self.response_content_json:
            return

        consolidated_response = None
        for decoded_line in self.response_content_json:
            if consolidated_response is None:
                # We have to do a dict copy because the old ones uhh disappear, for some reason.
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

        self.response_content_json = [consolidated_response]

    def request_content_as_json(self) -> dict | None:
        content_as_str = self.request_content_as_str('utf-8')
        if not content_as_str:
            return None

        return orjson.loads(content_as_str)

    def response_content_as_json(self) -> dict | None:
        # First, check if the parent class is hiding anything in self.response_content_chunks
        content_as_str = self.response_content_as_str('utf-8')
        if content_as_str:
            return orjson.loads(content_as_str)

        # Next, check if we need a consolidation
        if len(self.response_content_json) > 1:
            self.logger.info(f"{len(RequestInterceptor.response_content_json)=}, expected 1 => call consolidate first")
            return None

        return self.response_content_json[0]

    def update_access_event(
            self,
            do_commit: bool = True,
    ) -> None:
        merged_access = self.new_access

        request_json = self.request_content_as_json()
        if request_json:
            merged_access.request['content'] = request_json

        response_json = self.response_content_as_json()
        if not response_json:
            del merged_access.response['content']
        else:
            merged_access.response['content'] = response_json

        self.ratelimits_db.add(merged_access)
        if do_commit:
            self.ratelimits_db.commit()
