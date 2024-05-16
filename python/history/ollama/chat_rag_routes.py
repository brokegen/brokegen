import json
import logging
import re
from collections.abc import AsyncIterable, Iterable

import langchain_core.documents
import orjson
from fastapi import Request
from langchain.chains.combine_documents import create_stuff_documents_chain
from langchain.chains.retrieval import create_retrieval_chain
from langchain_community.llms.ollama import Ollama
from langchain_core.prompts import PromptTemplate
from pydantic import BaseModel
from starlette.background import BackgroundTask
from starlette.concurrency import iterate_in_threadpool
from starlette.responses import JSONResponse, StreamingResponse

from access.ratelimits import RatelimitsDB, RequestInterceptor
from history.database import HistoryDB, InferenceJob, ModelConfigRecord
from history.ollama.chat_routes import safe_get, lookup_model
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


async def construct_raw_prompt(
        plain_prompt: str,
        model: ModelConfigRecord,
        inference_job: InferenceJob,
) -> str | None:
    system_str = (
            safe_get(inference_job.overridden_inference_params, 'options', 'system')
            or safe_get(model.default_inference_params, 'system')
            or ''
    )

    template0 = (
            safe_get(inference_job.overridden_inference_params, 'options', 'template')
            or safe_get(model.default_inference_params, 'template')
            or ''
    )

    # Use the world's most terrible regexes to parse the Ollama template format
    template1 = template0
    try:
        if_pattern = r'{{-?\s*if\s+(\.[^\s]+)\s*}}(.*?){{-?\s*end\s*}}'
        while True:
            match = next(re.finditer(if_pattern, template1, re.DOTALL))
            if_match, block = match.groups()

            if system_str and if_match == '.System':
                substituted_block = block
            elif plain_prompt and if_match == '.Prompt':
                substituted_block = block
            else:
                substituted_block = ''

            template1 = re.sub(if_pattern, lambda m: substituted_block, template1, count=1, flags=re.DOTALL)

    except StopIteration:
        pass

    # And then substitute in the concrete values
    template3 = template1
    try:
        real_pattern = r'{{\s*(\.[^\s]+?)\s*\}}'
        while True:
            match = next(re.finditer(real_pattern, template3, re.DOTALL))
            (real_match,) = match.groups()

            if system_str and real_match == '.System':
                substituted_block = system_str
            elif plain_prompt and real_match == '.Prompt':
                substituted_block = plain_prompt
            elif real_match == '.Response':
                # Actually, we should just plain exit right after this match.
                template3 = template3[:match.start()]
                break
            else:
                substituted_block = ''

            template3 = re.sub(real_pattern, lambda m: substituted_block, template3, count=1, flags=re.DOTALL)

    except StopIteration:
        pass

    inference_job.raw_prompt = template3
    return template3


async def do_proxy_chat_norag(
        original_request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
        knowledge: KnowledgeSingleton,
):
    intercept = RequestInterceptor(logger, ratelimits_db)

    request_content_bytes: bytes = await original_request.body()
    request_content_json: dict = orjson.loads(request_content_bytes)
    model, executor_record = await lookup_model(original_request, request_content_json['model'], history_db,
                                                ratelimits_db)

    inference_job = InferenceJob(
        model_config=model.id,
        overridden_inference_params=request_content_json.get('options', None),
    )
    history_db.add(inference_job)
    history_db.commit()

    # Tweak the request so we see/add the `raw` prompting info
    try:
        constructed_prompt = await construct_raw_prompt(
            safe_get(request_content_json, 'prompt'),
            model,
            inference_job,
        )
    # If the regexes didn't match, eh
    except ValueError:
        constructed_prompt = None

    if constructed_prompt is not None:
        request_content_json['prompt'] = constructed_prompt
        request_content_json['raw'] = True
    else:
        logger.warning(f"Unable to do manual Ollama template substitution, debug it yourself later: {model.human_id}")

    # content-length header will no longer be correct
    modified_headers = original_request.headers.mutablecopy()
    del modified_headers['content-length']

    if request_content_json['raw']:
        for unsupported_field in ['template', 'system', 'context']:
            if unsupported_field in request_content_json:
                del request_content_json[unsupported_field]

    upstream_request = _real_ollama_client.build_request(
        method='POST',
        url="/api/chat",
        content=orjson.dumps(request_content_json),
        headers=modified_headers,
        cookies=original_request.cookies,
    )

    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)
    intercept.build_access_event(upstream_response, api_bucket=f"ollama:/api/chat")
    intercept._set_or_delete_request_content(request_content_json)

    async def on_done(consolidated_response_content_json):
        response_stats = dict(consolidated_response_content_json)
        done = safe_get(response_stats, 'done')
        if not done:
            logger.warning(f"/api/chat ran out of bytes to process, but Ollama JSON response is {done=}")

        if 'context' in response_stats:
            del response_stats['context']

        # We need to check for this in case of errors
        if 'response' in response_stats:
            del response_stats['response']

        merged_job = history_db.merge(inference_job)
        merged_job.response_stats = response_stats

        history_db.add(merged_job)
        history_db.commit()

    async def post_forward_cleanup():
        await upstream_response.aclose()

        as_json = orjson.loads(intercept.response_content_as_str('utf-8'))
        intercept._set_or_delete_response_content(as_json)

        intercept.new_access = ratelimits_db.merge(intercept.new_access)
        ratelimits_db.add(intercept.new_access)
        ratelimits_db.commit()

        await on_done(as_json[-1])

    return StreamingResponse(
        content=intercept.wrap_response_content_raw(upstream_response.aiter_raw()),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(post_forward_cleanup),
    )


async def do_proxy_chat_rag(
        original_request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
        knowledge: KnowledgeSingleton,
):
    return await do_proxy_chat_norag(original_request, history_db, ratelimits_db, knowledge)


async def do_transparent_rag(
        request: Request,
        knowledge: KnowledgeSingleton,
        context_template: str = """\
Use any sources you can. Some recent context is provided to try and provide newer information:

<context>
{context}
</context>

Reasoning: Let's think step by step in order to produce the answer.

Question: {input}""",
        print_all_response_data: bool = False,
):
    """
    This "transparent" proxy works okay for our purposes (not modifying client code), but is horribly brittle.

    TODO: Figure out how to plug in to/modify langchain so we can cache the raw request/response info.
    """
    request_content_json = orjson.loads(await request.body())
    llm = Ollama(
        model=request_content_json['model'],
    )

    prompt = PromptTemplate.from_template(context_template)
    document_chain = create_stuff_documents_chain(llm, prompt)

    retriever = knowledge.as_retriever(
        search_type='similarity',
        search_kwargs={
            'k': 18,
        },
    )
    retrieval_chain = create_retrieval_chain(retriever, document_chain)

    async def async_iter():
        # TODO: Sometimes the astream Chunk is too big
        async for chunk in retrieval_chain.astream({
            'input': request_content_json['prompt'],
        }):
            if not chunk.get('answer'):
                logger.debug(
                    f"Partial `retrieval_chain` response: {json.dumps(chunk, indent=2, default=document_encoder)}")
                continue

            ollama_style_response = dict()
            ollama_style_response['model'] = request_content_json['model']
            ollama_style_response['response'] = chunk['answer']
            ollama_style_response['done'] = False

            if print_all_response_data:
                logger.debug(json.dumps(ollama_style_response))
            yield ollama_style_response

        yield {
            'model': request_content_json['model'],
            'response': '',
            'done': True,
        }

    try:
        return JSONStreamingResponse(
            async_iter(),
            status_code=200,
        )
    except ValueError as e:
        # TODO: Check how many response chunks we've already tried streaming out;
        #       it's probably zero, but we should verify that, just in case.
        if str(e) == "Chunk too big":
            logger.warning("Failed to stream all this data, starting over in a non-stream mode."
                           "Hopefully this doesn't mess up the client.")
            stream = False
