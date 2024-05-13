try:
    import orjson as json
except ImportError:
    import json

import logging

from faiss import IndexFlatL2
from fastapi import APIRouter, Depends, FastAPI, Request
from langchain.chains.combine_documents import create_stuff_documents_chain
from langchain.chains.retrieval import create_retrieval_chain
from langchain_community.docstore import InMemoryDocstore
from langchain_community.embeddings import OllamaEmbeddings
from langchain_community.llms.ollama import Ollama
from langchain_community.vectorstores import FAISS
from langchain_core.prompts import PromptTemplate

from access.ratelimits import RatelimitsDB
from access.ratelimits import get_db as get_ratelimits_db
from inference.routes import forward_request, forward_request_nodetails

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)


async def do_transparent_rag(
        request: Request,
        context_template: str = """\
Use any sources you can. Some recent context is provided to try and provide newer information:

<context>
{context}
</context>

Reasoning: Let's think step by step in order to produce the answer.

Question: {input}""",
        embedder_name: str = 'nomic-embed-text:latest',
        embedder_dims: int = 768,
):
    """
    This "transparent" proxy works okay for our purposes (not modifying client code), but is horribly brittle.
    """
    request_content_json = json.loads(await request.body())
    llm = Ollama(model=request_content_json['model'])

    prompt = PromptTemplate.from_template(context_template)
    document_chain = create_stuff_documents_chain(llm, prompt)

    embedder = OllamaEmbeddings(model=embedder_name)
    dummy_vectorstore = FAISS(
        embedding_function=embedder,
        index=IndexFlatL2(embedder_dims),
        docstore=InMemoryDocstore(),
        index_to_docstore_id={},
    )
    retriever = dummy_vectorstore.as_retriever()

    retrieval_chain = create_retrieval_chain(retriever, document_chain)
    langchain_response = await retrieval_chain.ainvoke({'input': request_content_json['prompt']})

    # TODO: Mirror the Ollama fields as well as we can, without langchain eating the extras
    ollama_style_response = dict()
    ollama_style_response['model'] = request_content_json['model']
    ollama_style_response['response'] = langchain_response['answer']
    ollama_style_response['done'] = True

    if request_content_json.get('context'):
        ollama_style_response['context'] = request_content_json['context']

    # Pretty-print the actual output, since otherwise we'll never know what the True Context was.
    # TODO: Figure out how to plug in to/modify langchain so we can cache the raw request/response info.
    logger.info(
        json.dumps(langchain_response, indent=2)
    )

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
    ):
        if request.url.path == "/ollama-proxy/api/generate":
            return await do_transparent_rag(request)

        if (
                request.method == 'HEAD'
                or request.url.path == "/ollama-proxy/api/show"
        ):
            return await forward_request_nodetails(request, ratelimits_db)

        return await forward_request(request, ratelimits_db)

    app.include_router(ollama_forwarder)
