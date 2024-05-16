import logging
from collections.abc import AsyncIterable, Iterable
from typing import AsyncIterator

import langchain_core.documents
import orjson
from fastapi import Request
from langchain_core.documents import Document
from pydantic import BaseModel
from starlette.background import BackgroundTask
from starlette.concurrency import iterate_in_threadpool
from starlette.responses import JSONResponse, StreamingResponse

from access.ratelimits import RatelimitsDB, RequestInterceptor
from history.database import HistoryDB, InferenceJob
from history.ollama.chat_routes import safe_get, lookup_model, construct_raw_prompt
from history.ollama.forward_routes import _real_ollama_client
from inference.embeddings.knowledge import KnowledgeSingleton

logger = logging.getLogger(__name__)


class JSONStreamingResponse(StreamingResponse, JSONResponse):
    def __init__(
            self,
            content: Iterable | AsyncIterable,
            status_code: int = 200,
            headers: dict[str, str] | None = None,
            media_type: str | None = None,
            background: BackgroundTask | None = None,
    ) -> None:
        if isinstance(content, AsyncIterable):
            self._content_iterable: AsyncIterable = content
        else:
            self._content_iterable = iterate_in_threadpool(content)

        async def body_iterator() -> AsyncIterable[bytes]:
            async for content_ in self._content_iterable:
                if isinstance(content_, BaseModel):
                    content_ = content_.model_dump()
                yield self.render(content_)

        self.body_iterator = body_iterator()
        self.status_code = status_code
        if media_type is not None:
            self.media_type = media_type
        self.background = background
        self.init_headers(headers)


def document_encoder(obj):
    if isinstance(obj, langchain_core.documents.Document):
        return obj.to_json()
    else:
        return obj


async def _generate_raw(
        original_request: Request,
        request_content_json,
        prompt_override: str | None,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
):
    intercept = RequestInterceptor(logger, ratelimits_db)

    model, executor_record = await lookup_model(original_request, request_content_json['model'], history_db,
                                                ratelimits_db)

    inference_job = InferenceJob(
        model_config=model.id,
        overridden_inference_params=request_content_json.get('options', None),
    )
    history_db.add(inference_job)
    history_db.commit()

    # Tweak the request so we see/add the `raw` prompting info
    model_template = (
            safe_get(inference_job.overridden_inference_params, 'options', 'template')
            or safe_get(model.default_inference_params, 'template')
            or ''
    )

    system_message = (
            safe_get(inference_job.overridden_inference_params, 'options', 'system')
            or safe_get(model.default_inference_params, 'system')
            or ''
    )

    chat_messages = request_content_json['messages']
    del request_content_json['messages']

    # Convert the first message, and include the system prompt therein.
    # TODO: Figure out what to do with request that overflows context
    # TODO: Use pip `transformers` library to build from templates/etc
    converted_prompts = []
    for count, untemplated in enumerate(chat_messages):
        is_first_message = count == 0
        is_last_message = (
                count == len(chat_messages) - 1
                and prompt_override is None
        )

        converted = await construct_raw_prompt(
            model_template,
            system_message if is_first_message else '',
            untemplated['content'] if untemplated['role'] == 'user' else '',
            untemplated['content'] if untemplated['role'] == 'assistant' else '',
            is_last_message,
        )
        converted_prompts.append(converted)

    if prompt_override is not None:
        existing_content = sum(map(len, converted_prompts))
        # TODO: Figure out how/what to truncate
        logging.debug(
            f"Existing chat history is {existing_content} chars, adding override with length {len(prompt_override)}")

        converted_prompts.append(await construct_raw_prompt(
            model_template,
            '',
            prompt_override,
            '',
            True,
        ))

    inference_job.raw_prompt = '\n'.join(converted_prompts)
    request_content_json['prompt'] = '\n'.join(converted_prompts)
    request_content_json['raw'] = True

    for unsupported_field in ['template', 'system', 'context']:
        if unsupported_field in request_content_json:
            del request_content_json[unsupported_field]

    # content-length header will no longer be correct
    modified_headers = original_request.headers.mutablecopy()
    del modified_headers['content-length']

    modified_headers['url'] = str(_real_ollama_client.base_url) + "/api/generate"

    upstream_request = _real_ollama_client.build_request(
        method='POST',
        url="/api/generate",
        content=orjson.dumps(request_content_json),
        headers=modified_headers,
        cookies=original_request.cookies,
    )

    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)
    intercept.build_access_event(upstream_response, api_bucket=f"ollama:/api/generate")
    intercept._set_or_delete_request_content(request_content_json)

    async def on_done(consolidated_response_content_json):
        response_stats = dict(consolidated_response_content_json)
        done = safe_get(response_stats, 'done')
        if not done:
            logger.warning(f"/api/generate ran out of bytes to process, but Ollama JSON response is {done=}")

        merged_job = history_db.merge(inference_job)
        merged_job.response_stats = response_stats

        history_db.add(merged_job)
        history_db.commit()

    async def post_forward_cleanup():
        await upstream_response.aclose()

        intercept.consolidate_json_response()
        # TODO: Consolidate correctly, this isn't loading into the right place.
        as_json = intercept.response_content_as_json()
        intercept._set_or_delete_response_content(as_json)

        intercept.new_access = ratelimits_db.merge(intercept.new_access)
        ratelimits_db.add(intercept.new_access)
        ratelimits_db.commit()

        await on_done(as_json)

    async def translate_generate_to_chat() -> AsyncIterator[bytes]:
        primordial = intercept.wrap_response_content(upstream_response.aiter_lines())
        async for chunk0 in primordial:
            # Convert the "response" field to "message { content, role }"
            # TODO: How to deal with ndjson chunks that are split across chunks
            chunk1 = orjson.loads(chunk0)
            chunk1_message = {
                'content': chunk1['response'],
                'role': 'assistant',
            }

            del chunk1['response']
            chunk1['message'] = chunk1_message

            yield orjson.dumps(chunk1)

    return StreamingResponse(
        content=translate_generate_to_chat(),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(post_forward_cleanup),
    )


async def do_proxy_chat_norag(
        original_request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
        knowledge: KnowledgeSingleton,
):
    request_content_bytes: bytes = await original_request.body()
    request_content_json: dict = orjson.loads(request_content_bytes)

    return await _generate_raw(
        original_request,
        request_content_json,
        None,
        history_db,
        ratelimits_db,
    )


async def do_proxy_chat_rag(
        original_request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
        knowledge: KnowledgeSingleton,
):
    request_content_bytes: bytes = await original_request.body()
    request_content_json: dict = orjson.loads(request_content_bytes)

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
                logger.debug(f"Last remaining RAG doc is {len(docs[0])} chars, truncating")
                formatted_docs = docs[0][:20_000]

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

    return await _generate_raw(
        original_request,
        request_content_json,
        big_prompt,
        history_db,
        ratelimits_db,
    )
