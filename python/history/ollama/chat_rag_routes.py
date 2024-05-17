import logging
from collections.abc import AsyncIterable
from datetime import datetime, timezone
from typing import TypeAlias, Callable, Awaitable, Any

import httpx
import orjson
import starlette.datastructures
import starlette.requests
from fastapi import Request
from langchain_core.documents import Document
from starlette.background import BackgroundTask
from starlette.responses import StreamingResponse

from access.ratelimits import RatelimitsDB, ApiAccessWithResponse
from history.database import HistoryDB, InferenceJob
from history.ollama.chat_routes import safe_get, lookup_model_offline
from history.ollama.forward_routes import _real_ollama_client
from history.ollama.json import OllamaRequestContentJSON, OllamaResponseContentJSON, JSONRequestInterceptor, \
    JSONStreamingResponse, chunk_and_log_output
from history.prompting import apply_llm_template, PromptText, TemplatedPromptText
from inference.embeddings.knowledge import KnowledgeSingleton

logger = logging.getLogger(__name__)

OllamaModelName: TypeAlias = str


async def do_generate_raw_templated(
        request_content: OllamaRequestContentJSON,
        request_headers: starlette.datastructures.Headers,
        request_cookies: httpx.Cookies | None,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
        on_done_fn: Callable[[OllamaResponseContentJSON], Awaitable[Any]] | None = None,
):
    intercept = JSONRequestInterceptor(logger, ratelimits_db)

    model, executor_record = await lookup_model_offline(
        request_content['model'],
        history_db,
    )

    inference_job = InferenceJob(
        raw_prompt=request_content['prompt'],
        model_config=model.id,
        overridden_inference_params=request_content.get('options', None),
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

    # TODO: We should have real timing and instrumentation calls,
    #       but the timestamps for this will suffice, for our single-threaded purposes.
    logger.debug(f"Done pre-processing, forwarding request to Ollama: {request_content['prompt'][:280]}")
    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)
    intercept.build_access_event(upstream_response, api_bucket=f"ollama:/api/generate")
    # TODO: The request_content was available a long time ago, it should have been stored right away.
    # Would it be easier to review all usages of this, or check httpx/starlette for proper middleware support?
    intercept._set_or_delete_request_content(request_content)

    async def finalize_inference_job(response_content_json: OllamaResponseContentJSON):
        response_stats = dict(response_content_json)
        done = safe_get(response_stats, 'done')
        if not done:
            logger.warning(f"/api/generate ran out of bytes to process, but Ollama JSON response is {done=}")

        merged_job = history_db.merge(inference_job)
        merged_job.response_stats = response_stats

        history_db.add(merged_job)
        history_db.commit()

    async def finalize_intercept() -> OllamaResponseContentJSON:
        await intercept.consolidate_json_response()
        intercept.new_access = ratelimits_db.merge(intercept.new_access)

        # TODO: Consolidate correctly, this isn't loading into the right place.
        as_json: OllamaResponseContentJSON = intercept.response_content_as_json()
        intercept._set_or_delete_response_content(as_json)

        ratelimits_db.add(intercept.new_access)
        ratelimits_db.commit()

        return as_json

    async def post_forward_cleanup():
        await upstream_response.aclose()

        as_json = await finalize_intercept()
        await finalize_inference_job(as_json)
        if on_done_fn is not None:
            await on_done_fn(as_json)

    return StreamingResponse(
        content=intercept.wrap_response_content(upstream_response.aiter_lines()),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(post_forward_cleanup),
    )


async def convert_chat_to_generate(
        original_request: starlette.requests.Request,
        chat_request_content: OllamaRequestContentJSON,
        prompt_override: PromptText | None,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
):
    model, executor_record = await lookup_model_offline(
        chat_request_content['model'],
        history_db,
    )

    model_template = (
            safe_get(chat_request_content, 'options', 'template')
            or safe_get(model.default_inference_params, 'template')
            or ''
    )

    system_message = (
            safe_get(chat_request_content, 'options', 'system')
            or safe_get(model.default_inference_params, 'system')
            or ''
    )

    ollama_chat_messages = chat_request_content['messages']
    templated_messages: list[TemplatedPromptText] = []

    # TODO: Figure out what to do with request that overflows context
    # TODO: Use pip `transformers` library to build from templates/etc
    for count, message in enumerate(ollama_chat_messages):
        is_first_message = count == 0
        is_last_message = (
                count == len(ollama_chat_messages) - 1
                and prompt_override is None
        )

        converted = await apply_llm_template(
            model_template,
            system_message if is_first_message else '',
            message['content'] if message['role'] == 'user' else '',
            message['content'] if message['role'] == 'assistant' else '',
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
                f"adding prompt_override with length {len(prompt_override)}")

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
        ratelimits_db,
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
        content=chunk_and_log_output(
            translate_generate_to_chat(generate_response.body_iterator),
            lambda s: logger.debug(f"/api/chat: " + s),
        ),
        status_code=generate_response.status_code,
        headers=converted_response_headers,
        background=generate_response.background,
    )


async def do_proxy_chat_norag(
        original_request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
):
    logger.debug(f"Received /api/chat request, starting processing")

    request_content_bytes: bytes = await original_request.body()
    request_content_json: dict = orjson.loads(request_content_bytes)

    ollama_response = await convert_chat_to_generate(
        original_request,
        request_content_json,
        None,
        history_db,
        ratelimits_db,
    )

    # TODO: This/these should really be middleware.
    new_access = ApiAccessWithResponse(
        api_bucket="self:do_proxy_chat_norag()",
        accessed_at=datetime.now(tz=timezone.utc),
        api_endpoint=str(original_request.url),
        request={
            "note": "not done implementing",
            "content": request_content_json,
        },
        response={
            "note": "not done implementing either",
        },
    )
    ratelimits_db.add(new_access)
    ratelimits_db.commit()

    return ollama_response


async def do_proxy_chat_rag(
        original_request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
        knowledge: KnowledgeSingleton,
):
    request_content_bytes: bytes = await original_request.body()
    request_content_json: OllamaRequestContentJSON = orjson.loads(request_content_bytes)

    retriever = knowledge.as_retriever(
        search_type='similarity',
        search_kwargs={
            'k': 18,
        },
    )

    last_message = request_content_json['messages'][-1]
    retrieval_str = last_message['content']
    docs: list[Document] = await retriever.ainvoke(retrieval_str)

    formatted_docs = '\n\n'.join(
        [d.page_content for d in docs]
    )
    if len(formatted_docs) > 20_000:
        logger.debug(f"Returned {len(docs)} docs, with {len(formatted_docs)} chars text, truncating")
        while len(formatted_docs) > 20_000:
            if len(docs) == 1:
                logger.debug(f"Last remaining RAG doc is {len(docs[0].page_content)} chars, truncating")
                formatted_docs = docs[0][:20_000]
                break

            docs = docs[:-1]
            formatted_docs = '\n\n'.join(
                [d.page_content for d in docs]
            )

    logger.info(f"Final RAG context is {len(docs)} docs, with {len(formatted_docs)} chars")

    big_prompt = f"""\
Use any sources you can. Some recent context is provided to try and provide newer information:

<context>
{formatted_docs}
</context>

Reasoning: Let's think step by step in order to produce the answer.

Question: {last_message['content']}
"""

    return await convert_chat_to_generate(
        original_request,
        request_content_json,
        big_prompt,
        history_db,
        ratelimits_db,
    )
