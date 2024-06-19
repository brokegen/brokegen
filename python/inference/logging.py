import logging
from typing import AsyncIterator, Callable, TypeVar, Awaitable, Any

from orjson import orjson

from _util.json import JSONDict
from providers.inference_models.database import HistoryDB

logger = logging.getLogger(__name__)


async def encode_to_bytes(primordial: AsyncIterator[str]) -> AsyncIterator[bytes]:
    chunk: str
    async for chunk in primordial:
        yield chunk.encode()


async def decode_from_bytes(primordial0: AsyncIterator[bytes]) -> AsyncIterator[str]:
    chunk0: bytes
    async for chunk0 in primordial0:
        yield chunk0.decode()


async def stream_str_to_json(
        primordial: AsyncIterator[str],
) -> AsyncIterator[JSONDict]:
    """
    This extra per-packet conversion is undoubtedly costly, but developer time is costlier.
    """
    return stream_bytes_to_json(
        encode_to_bytes(primordial)
    )


async def stream_bytes_to_json(
        primordial0: AsyncIterator[bytes],
) -> AsyncIterator[JSONDict]:
    """
    Sometimes, a given JSON response is split across chunks.
    Try to consolidate them before decoding, maybe.
    """
    buffered_chunks: list[bytes] = []

    async for chunk0 in primordial0:
        if buffered_chunks:
            try:
                buffered_chunks.append(chunk0)
                buffered_json: JSONDict = orjson.loads(
                    b''.join(buffered_chunks)
                )

                yield buffered_json
                buffered_chunks = []

            except orjson.JSONDecodeError:
                pass

        else:
            try:
                chunk0_json: JSONDict = orjson.loads(chunk0)
                yield chunk0_json

            except orjson.JSONDecodeError:
                buffered_chunks.append(chunk0)

        if buffered_chunks:
            logger.fatal(f"Failed to decode {len(b''.join(buffered_chunks))} bytes in JSON response")
            raise RuntimeError(f"Failed to decode {len(b''.join(buffered_chunks))} bytes in JSON response")


T = TypeVar('T')
U = TypeVar('U')


async def tee_to_console_output(
        primordial_t: AsyncIterator[T],
        indexer: Callable[[T], str],
        max_buffer_len: int = 120,
) -> AsyncIterator[T]:
    buffer = ""

    async for chunk_t in primordial_t:
        yield chunk_t

        if len(buffer) >= max_buffer_len:
            print(buffer)
            buffer = indexer(chunk_t)
        else:
            buffer += indexer(chunk_t)

    if buffer:
        print(buffer)
        del buffer


async def consolidate_and_call(
        primordial_t: AsyncIterator[T],
        consolidator: Callable[[T, U], U],
        initializer: U,
        *on_done_fns: Callable[[U], Awaitable[Any]],
) -> AsyncIterator[T]:
    """
    This is basically an async functools.reduce()
    """
    consolidated_response: U = initializer

    async for chunk_t in primordial_t:
        yield chunk_t
        consolidated_response = consolidator(chunk_t, consolidated_response)

    for on_done_fn in on_done_fns:
        await on_done_fn(consolidated_response)


async def inference_event_logger(
        consolidated_response: JSONDict,
        history_db: HistoryDB,
):
    pass


async def construct_new_sequence_from(
        consolidated_response: JSONDict,
        history_db: HistoryDB,
):
    pass
