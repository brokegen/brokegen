from datetime import datetime, timezone
from typing import TypeAlias, Callable, Awaitable, Any, AsyncIterator

import httpx
import orjson
import starlette.datastructures
import starlette.responses

from _util.json import JSONDict
from audit.http import AuditDB
from audit.http_raw import HttpxLogger
from client.database import HistoryDB
from inference.iterators import stream_bytes_to_json, consolidate_and_call, dump_to_bytes
from providers.inference_models.orm import InferenceEventOrm, InferenceReason
from providers_registry.ollama.api_chat.logging import finalize_inference_job, OllamaRequestContentJSON, \
    OllamaResponseContentJSON, ollama_log_indexer, ollama_response_consolidator
from providers_registry.ollama.chat_routes import lookup_model_offline
from providers_registry.ollama.json import OllamaEventBuilder
from providers_registry.ollama.model_routes import _real_ollama_client
from audit.http import get_db as get_audit_db

OllamaModelName: TypeAlias = str


async def do_generate_nolog(
        request_content: OllamaRequestContentJSON,
) -> httpx.Response:
    upstream_request = _real_ollama_client.build_request(
        method='POST',
        url="/api/generate",
        content=orjson.dumps(request_content),
        # https://github.com/encode/httpx/discussions/2959
        # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
        headers=[('Connection', 'close')],
    )

    with HttpxLogger(_real_ollama_client, next(get_audit_db())):
        upstream_response = await _real_ollama_client.send(upstream_request, stream=True)

    return upstream_response


async def do_generate_raw_templated(
        request_content: OllamaRequestContentJSON,
        request_headers: starlette.datastructures.Headers,
        request_cookies: httpx.Cookies | None,
        history_db: HistoryDB,
        audit_db: AuditDB,
        inference_reason: InferenceReason | None = None,
) -> starlette.responses.StreamingResponse:
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
        merged_job.response_info = dict(response_content_json)

        history_db.add(merged_job)
        history_db.commit()

    with HttpxLogger(_real_ollama_client, audit_db):
        upstream_response = await _real_ollama_client.send(upstream_request, stream=True)
        wrapped_response: starlette.responses.StreamingResponse = await intercept.wrap_entire_streaming_response(upstream_response)

        iter0: AsyncIterator[bytes] = wrapped_response.body_iterator
        iter1: AsyncIterator[JSONDict] = stream_bytes_to_json(iter0)
        iter2: AsyncIterator[JSONDict] = consolidate_and_call(
            iter1, ollama_response_consolidator, {},
            do_finalize_inference_job,
        )
        iter3: AsyncIterator[bytes] = dump_to_bytes(iter2)

        wrapped_response.body_iterator = iter3
        return wrapped_response
