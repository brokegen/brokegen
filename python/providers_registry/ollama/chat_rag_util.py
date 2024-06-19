from datetime import datetime, timezone
from typing import TypeAlias, Callable, Awaitable, Any

import httpx
import orjson
import starlette.datastructures

from audit.http import AuditDB
from audit.http_raw import HttpxLogger
from client.database import HistoryDB
from providers.inference_models.orm import InferenceEventOrm, InferenceReason
from providers_registry.ollama.api_chat.logging import finalize_inference_job
from providers_registry.ollama.chat_routes import lookup_model_offline
from providers_registry.ollama.json import OllamaResponseContentJSON, OllamaRequestContentJSON, OllamaEventBuilder
from providers_registry.ollama.model_routes import _real_ollama_client

OllamaModelName: TypeAlias = str


async def do_generate_raw_templated(
        request_content: OllamaRequestContentJSON,
        request_headers: starlette.datastructures.Headers,
        request_cookies: httpx.Cookies | None,
        history_db: HistoryDB,
        audit_db: AuditDB,
        inference_reason: InferenceReason | None = None,
        on_done_fn: Callable[[OllamaResponseContentJSON], Awaitable[Any]] | None = None,
):
    intercept = OllamaEventBuilder("ollama:/api/generate", audit_db)

    model, executor_record = await lookup_model_offline(request_content['model'], history_db)

    inference_job = InferenceEventOrm(
        model_record_id=model.id,
        prompt_with_templating=request_content['prompt'],
        response_created_at=datetime.now(tz=timezone.utc),
        response_error="[haven't received/finalized response info yet]",
        reason=inference_reason,
    )
    history_db.add(inference_job)
    history_db.commit()

    upstream_request = _real_ollama_client.build_request(
        method='POST',
        url="/api/generate",
        content=orjson.dumps(intercept.wrap_request(request_content)),
        # https://github.com/encode/httpx/discussions/2959
        # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
        headers=[('Connection', 'close')],
        cookies=request_cookies,
    )

    async def do_finalize_inference_job(response_content_json: OllamaResponseContentJSON):
        merged_job = history_db.merge(inference_job)
        finalize_inference_job(merged_job, response_content_json)

        history_db.add(merged_job)
        history_db.commit()

    with HttpxLogger(_real_ollama_client, audit_db):
        upstream_response = await _real_ollama_client.send(upstream_request, stream=True)

    return await intercept.wrap_entire_streaming_response(upstream_response, do_finalize_inference_job, on_done_fn)
