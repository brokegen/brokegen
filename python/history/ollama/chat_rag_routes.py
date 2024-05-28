import logging
from collections.abc import AsyncIterable
from datetime import datetime
from typing import TypeAlias, Callable, Awaitable, Any, AsyncIterator

import httpx
import orjson
import starlette.datastructures
import starlette.requests
from starlette.exceptions import HTTPException

from _util.json import JSONStreamingResponse, safe_get, JSONArray
from audit.http import AuditDB
from audit.http_raw import HttpxLogger
from history.ollama.chat_routes import lookup_model_offline
from history.ollama.json import OllamaRequestContentJSON, OllamaResponseContentJSON, \
    consolidate_stream, OllamaEventBuilder
from inference.embeddings.retrieval import RetrievalPolicy
from inference.prompting.templating import apply_llm_template
from _util.typing import PromptText, TemplatedPromptText
from providers.inference_models.database import HistoryDB
from providers.inference_models.orm import InferenceEventOrm, InferenceReason
from providers.ollama import _real_ollama_client

logger = logging.getLogger(__name__)

OllamaModelName: TypeAlias = str


def finalize_inference_job(
        inference_job: InferenceEventOrm,
        response_content_json: OllamaResponseContentJSON,
):
    if safe_get(response_content_json, 'prompt_eval_count'):
        inference_job.prompt_tokens = safe_get(response_content_json, 'prompt_eval_count')
    if safe_get(response_content_json, 'prompt_eval_duration'):
        inference_job.prompt_eval_time = safe_get(response_content_json, 'prompt_eval_duration') / 1e9

    if safe_get(response_content_json, 'created_at'):
        inference_job.response_created_at = datetime.fromisoformat(safe_get(response_content_json, 'created_at'))
    if safe_get(response_content_json, 'eval_count'):
        inference_job.response_tokens = safe_get(response_content_json, 'eval_count')
    if safe_get(response_content_json, 'eval_duration'):
        inference_job.response_eval_time = safe_get(response_content_json, 'eval_duration') / 1e9

    # TODO: I'm not sure this is even the actual field to check
    if safe_get(response_content_json, 'error'):
        inference_job.response_error = safe_get(response_content_json, 'error')

    inference_job.response_info = dict(response_content_json)


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

    if safe_get(request_content, 'options'):
        raise NotImplementedError(
            "Haven't implemented handling of override options! Need to construct a new ModelConfig.")

    inference_job = InferenceEventOrm(
        model_record_id=model.id,
        prompt_with_templating=request_content['prompt'],
        reason=inference_reason,
    )
    history_db.add(inference_job)
    history_db.commit()

    upstream_request = _real_ollama_client.build_request(
        method='POST',
        url="/api/generate",
        content=orjson.dumps(request_content),
        headers=request_headers,
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


async def convert_chat_to_generate(
        original_request: starlette.requests.Request,
        chat_request_content: OllamaRequestContentJSON,
        prompt_override: PromptText | None,
        history_db: HistoryDB,
        audit_db: AuditDB,
):
    model, executor_record = await lookup_model_offline(
        chat_request_content['model'],
        history_db,
    )

    model_template = (
            safe_get(chat_request_content, 'options', 'template')
            or safe_get(model.combined_inference_parameters, 'template')
            or ''
    )
    if not model_template:
        logger.error(f"No Ollama template info for {model.human_id}, fill it in with an /api/show proxy call")
        raise HTTPException(500, "No model template available, confirm that InferenceModelRecords are complete")

    system_message = (
            safe_get(chat_request_content, 'options', 'system')
            or safe_get(model.combined_inference_parameters, 'system')
            or ''
    )

    ollama_chat_messages = chat_request_content['messages']
    templated_messages: list[TemplatedPromptText] = []

    # TODO: Figure out what to do with request that overflows context
    #
    # TODO: Due to how Ollama templating is implemented, we basically need to bundle user/assistant requests together.
    #       Rather than doing this, just expect the user to have overridden the default templates, for now.
    #       Otherwise, we can check what happens with a null-every string message vs a non-null-assistant message.
    for count, message in enumerate(ollama_chat_messages):
        is_first_message = count == 0
        is_last_message = (
                count == len(ollama_chat_messages) - 1
                and prompt_override is None
        )

        converted = await apply_llm_template(
            model_template,
            system_message if is_first_message else None,
            message['content'] if message['role'] == 'user' else None,
            message['content'] if message['role'] == 'assistant' else None,
            is_last_message,
        )
        templated_messages.append(converted)

    if prompt_override is not None:
        # If we only have one message, then override differently
        if len(ollama_chat_messages) == 0:
            templated_messages = [await apply_llm_template(
                model_template,
                system_message,
                prompt_override,
                '',
                break_early_on_response=True,
            )]
        else:
            # TODO: Figure out how/what to truncate
            existing_content = sum(map(len, templated_messages))
            logging.debug(
                f"Existing chat history is {existing_content} chars, "
                f"adding prompt_override with length {len(prompt_override)}:\n"
                f"{prompt_override[:120]}"
            )

            templated_messages.append(await apply_llm_template(
                model_template,
                '',
                prompt_override,
                '',
                break_early_on_response=True,
            ))

    generate_request_content = dict(chat_request_content)
    generate_request_content['prompt'] = '\n'.join(templated_messages)
    generate_request_content['raw'] = True

    for unsupported_field in ['messages', 'template', 'system', 'context']:
        if unsupported_field in generate_request_content:
            del generate_request_content[unsupported_field]

    # content-length header will no longer be correct
    modified_headers = original_request.headers.mutablecopy()
    del modified_headers['content-length']

    generate_response = await do_generate_raw_templated(
        generate_request_content,
        modified_headers,
        httpx.Cookies(original_request.cookies),
        history_db,
        audit_db,
    )

    async def translate_generate_to_chat(
            primordial: AsyncIterable[str | bytes],
    ) -> AsyncIterable[bytes]:
        """
        Technically, this would be easier as a simple callback,
        rather than constructing a duplicate StreamingResponse. Whatever.

        TODO: How to deal with ndjson chunks that are split across chunks
        """
        async for chunk0 in primordial:
            chunk0_json = orjson.loads(chunk0)

            chunk1 = dict(chunk0_json)
            del chunk1['response']
            chunk1['message'] = {
                'content': chunk0_json['response'],
                'role': 'assistant',
            }

            yield orjson.dumps(chunk1)

    # DEBUG: content-length is also still not correct, sometimes?
    # I would guess this only happens for `stream=false` requests, because otherwise how would this make sense?
    converted_response_headers = dict(generate_response.headers)
    for unsupported_field in ['content-length']:
        if unsupported_field in converted_response_headers:
            del converted_response_headers[unsupported_field]

    return JSONStreamingResponse(
        content=translate_generate_to_chat(generate_response.body_iterator),
        status_code=generate_response.status_code,
        headers=converted_response_headers,
        background=generate_response.background,
    )


async def do_proxy_chat_rag(
        original_request: starlette.requests.Request,
        retrieval_policy: RetrievalPolicy,
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> JSONStreamingResponse:
    request_content_bytes: bytes = await original_request.body()
    request_content_json: OllamaRequestContentJSON = orjson.loads(request_content_bytes)

    # For now, everything we could possibly retrieve is from intercepting an Ollama /api/chat,
    # so there's no need to check for /api/generate's 'content' field.
    chat_messages: JSONArray | None = safe_get(request_content_json, 'messages')
    if not chat_messages:
        raise RuntimeError("No 'messages' provided in call to /api/chat")

    async def generate_retrieval_str(retrieval_query: TemplatedPromptText) -> PromptText:
        response0 = await do_generate_raw_templated(
            request_content={
                'model': request_content_json['model'],
                'prompt': retrieval_query,
                'raw': False,
                'stream': False,
            },
            request_headers=starlette.datastructures.Headers(),
            request_cookies=None,
            history_db=history_db,
            audit_db=audit_db,
        )

        content_chunks = []
        async for chunk in response0.body_iterator:
            content_chunks.append(chunk)

        response0_json = orjson.loads(''.join(content_chunks))
        return response0_json['response']

    async def generate_helper_fn(
            system_message: PromptText | None,
            user_prompt: PromptText | None,
            assistant_response: PromptText | None = None,
            inference_reason: InferenceReason | None = None,
    ) -> PromptText:
        model, executor_record = await lookup_model_offline(
            request_content_json['model'],
            history_db,
        )

        model_template = (
                safe_get(request_content_json, 'options', 'template')
                or safe_get(model.combined_inference_parameters, 'template')
                or ''
        )

        final_system_message = (
                system_message
                or safe_get(request_content_json, 'options', 'system')
                or safe_get(model.combined_inference_parameters, 'system')
                or None
        )

        templated_query = await apply_llm_template(
            model_template=model_template,
            system_message=final_system_message,
            user_prompt=user_prompt,
            assistant_response=assistant_response,
            break_early_on_response=True)
        response0 = await do_generate_raw_templated(
            request_content={
                'model': request_content_json['model'],
                'prompt': templated_query,
                'raw': False,
                'stream': False,
            },
            request_headers=starlette.datastructures.Headers(),
            request_cookies=None,
            history_db=history_db,
            audit_db=audit_db,
            inference_reason=inference_reason,
        )

        content_chunks = []
        async for chunk in response0.body_iterator:
            content_chunks.append(chunk)

        response0_json = orjson.loads(''.join(content_chunks))
        return response0_json['response']

    prompt_override = await retrieval_policy.parse_chat_history(
        chat_messages, generate_helper_fn, generate_retrieval_str
    )

    ollama_response = await convert_chat_to_generate(
        original_request,
        request_content_json,
        prompt_override,
        history_db,
        audit_db,
    )

    async def wrap_response(
            upstream_response: JSONStreamingResponse,
            log_output: bool = True,
    ) -> JSONStreamingResponse:
        async def identity_proxy(primordial):
            """This mostly exists for regression testing/checking, unfortunately"""
            async for chunk in primordial:
                yield chunk

        upstream_response._content_iterable = identity_proxy(upstream_response._content_iterable)
        upstream_response._content_iterable = identity_proxy(upstream_response._content_iterable)

        if not log_output:
            return upstream_response

        if log_output:
            # TODO: Make sure this doesn't block execution, or whatever.
            # TODO: Figure out how to trigger two AsyncIterators at once, but we've already burned a day on it.
            async def big_fake_tee(primordial: AsyncIterator[bytes]) -> AsyncIterator[bytes]:
                stored_chunks = []
                buffered_text = ''

                async for chunk0 in primordial:
                    yield chunk0
                    stored_chunks.append(chunk0)

                    chunk0_json = orjson.loads(chunk0)
                    if len(buffered_text) >= 120:
                        print(buffered_text)
                        buffered_text = safe_get(chunk0_json, 'message', 'content')
                    else:
                        buffered_text += safe_get(chunk0_json, 'message', 'content')

                if buffered_text:
                    print(buffered_text)
                    del buffered_text

                async def replay_chunks():
                    for chunk in stored_chunks:
                        yield chunk

                async def to_json(primo: AsyncIterable) -> AsyncIterable[OllamaResponseContentJSON]:
                    async for chunk in primo:
                        yield orjson.loads(chunk)

                _ = await consolidate_stream(to_json(replay_chunks()))

            upstream_response._content_iterable = big_fake_tee(upstream_response._content_iterable)
            return upstream_response

    return await wrap_response(ollama_response)
