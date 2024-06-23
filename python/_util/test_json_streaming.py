import asyncio
from datetime import datetime, timezone
from typing import Callable, Awaitable, AsyncIterator

import orjson

from _util.json import safe_get
from _util.json_streaming import emit_keepalive_chunks_with_log, JSONStreamingResponse
from _util.typing import FoundationModelHumanID


async def complex_nothing_chain(
        inference_model_human_id: FoundationModelHumanID,
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

    async for chunk in emit_keepalive_chunks_with_log(fake_timeout(), 0.5, None):
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
