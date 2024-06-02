import asyncio
import logging
from collections.abc import AsyncIterable
from datetime import datetime, timezone
from typing import Callable, Awaitable, AsyncIterator, TypeVar, Any
from typing import Iterable

import orjson
import starlette.datastructures
import starlette.requests
from starlette.background import BackgroundTask
from starlette.concurrency import iterate_in_threadpool
from starlette.responses import StreamingResponse, JSONResponse

from _util.json import safe_get, JSONDict
from _util.json_streaming import emit_keepalive_chunks
from _util.typing import InferenceModelHumanID
from _util.json import safe_get


async def complex_nothing_chain(
        inference_model_human_id: InferenceModelHumanID,
        is_disconnected: Callable[[], Awaitable[bool]],
):
    async def fake_timeout(
            bigsleep_sec: float = 30.1,
            bigsleep_times: int = 3,
    ) -> AsyncIterator[str]:
        for _ in range(bigsleep_times):
            await asyncio.sleep(bigsleep_sec)
            yield orjson.dumps({
                "model": inference_model_human_id,
                "created_at": datetime.now(tz=timezone.utc),
                "message": {
                    "content": f"!",
                    "role": "assistant",
                },
                "done": False,
            })

        yield orjson.dumps({
            "model": inference_model_human_id,
            "created_at": datetime.now(tz=timezone.utc),
            "message": {
                "content": f"\nInference timeout after {bigsleep_sec} seconds: {inference_model_human_id}",
                "role": "assistant",
            },
            "done": True,
        })

    async for chunk in emit_keepalive_chunks(fake_timeout(), 0.5, None):
        if await is_disconnected():
            print(f"Somehow detected a client disconnect! (Expected client to just stop iteration)")

        if chunk is None:
            yield orjson.dumps({
                "model": inference_model_human_id,
                "created_at": datetime.now(tz=timezone.utc),
                "message": {
                    # On testing, we don't even need this field, so empty string is fine
                    "content": "",
                    "role": "assistant",
                },
                "done": False,
                # Add random fields, since clients seem robust
                "response": "",
                "status": "Waiting for Ollama response",
            })
            continue

        yield chunk


def disabled_test_nothing_chain(request_content_json, original_request):
    return JSONStreamingResponse(
        content=complex_nothing_chain(
            safe_get(request_content_json, 'model'),
            original_request.is_disconnected,
        ),
        status_code=200,
    )
