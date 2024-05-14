try:
    import orjson as fast_json
except ImportError:
    import json as fast_json

import json
import logging
from collections.abc import AsyncIterable, Iterable

import langchain_core.documents
from fastapi import APIRouter, Depends, FastAPI, Request
from langchain.chains.combine_documents import create_stuff_documents_chain
from langchain.chains.retrieval import create_retrieval_chain
from langchain_community.llms.ollama import Ollama
from langchain_core.prompts import PromptTemplate
from pydantic import BaseModel
from starlette.background import BackgroundTask
from starlette.concurrency import iterate_in_threadpool
from starlette.responses import JSONResponse, StreamingResponse

from access.ratelimits import RatelimitsDB
from access.ratelimits import get_db as get_ratelimits_db
from inference.embeddings.knowledge import KnowledgeSingleton, get_knowledge_dependency
from inference.routes import forward_request, forward_request_nodetails

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
        stream: bool = True,
        print_all_response_data: bool = False,
):
    """
    This "transparent" proxy works okay for our purposes (not modifying client code), but is horribly brittle.

    TODO: Figure out how to plug in to/modify langchain so we can cache the raw request/response info.
    """
    request_content_json = fast_json.loads(await request.body())
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

    if stream:
        async def async_iter():
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

        return JSONStreamingResponse(
            async_iter(),
            status_code=200,
        )

    else:
        langchain_response = await retrieval_chain.ainvoke({'input': request_content_json['prompt']})

        ollama_style_response = dict()
        ollama_style_response['model'] = request_content_json['model']
        ollama_style_response['response'] = langchain_response['answer']
        ollama_style_response['done'] = True

        # Pretty-print the actual output, since otherwise we'll never know what the True Context was.
        logger.info(json.dumps(langchain_response, indent=2, default=document_encoder))
        return ollama_style_response


def install_langchain_routes(app: FastAPI):
    ollama_forwarder = APIRouter()

    # TODO: Either OpenAPI or FastAPI doesn't parse these `{path:path}` directives correctly
    @ollama_forwarder.get("/ollama-proxy/{path:path}")
    @ollama_forwarder.head("/ollama-proxy/{path:path}")
    @ollama_forwarder.post("/ollama-proxy/{path:path}")
    async def do_proxy_get_post(
            request: Request,
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
            knowledge: KnowledgeSingleton = Depends(get_knowledge_dependency),
    ):
        if request.url.path == "/ollama-proxy/api/generate":
            return await do_transparent_rag(request, knowledge)

        if (
                request.method == 'HEAD'
                or request.url.path == "/ollama-proxy/api/show"
        ):
            return await forward_request_nodetails(request, ratelimits_db)

        return await forward_request(request, ratelimits_db)

    app.include_router(ollama_forwarder)
