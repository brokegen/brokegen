import logging
from contextlib import contextmanager
from typing import AsyncIterable, Annotated

import orjson
import starlette.datastructures
from fastapi import FastAPI, APIRouter, Depends, Query
from starlette.requests import Request
from starlette.responses import JSONResponse

from access.ratelimits import RatelimitsDB, get_db as get_ratelimits_db
from embeddings.retrieval import SkipRetrievalPolicy, CustomRetrievalPolicy
from history.database import HistoryDB, get_db as get_history_db
from history.ollama.chat_rag_routes import do_proxy_chat_rag, convert_chat_to_generate, \
    OllamaModelName, do_generate_raw_templated
from history.ollama.chat_routes import do_proxy_generate, lookup_model_offline
from history.ollama.forward_routes import forward_request_nodetails, forward_request, forward_request_nolog
from history.ollama.json import consolidate_stream, OllamaResponseContentJSON, chunk_and_log_output, safe_get
from history.ollama.model_routes import do_api_tags, do_api_show
from inference.embeddings.knowledge import KnowledgeSingleton, get_knowledge_dependency
from inference.prompting.templating import TemplatedPromptText, apply_llm_template

logger = logging.getLogger(__name__)


@contextmanager
def disable_info_logs(*logger_names):
    previous_levels = {}

    for name in logger_names:
        previous_levels[name] = logging.getLogger(name).level
        logging.getLogger(name).setLevel(max(previous_levels[name], logging.WARNING))

    try:
        yield

    finally:
        for name in logger_names:
            logging.getLogger(name).setLevel(previous_levels[name])


def install_test_points(app: FastAPI):
    router = APIRouter()

    ollama_api_options_str = """\
Ollama API parameters, desc from <https://github.com/ollama/ollama/blob/main/docs/api.md>.  
Note that these will override anything set in the model templates!

- `num_predict`: Maximum number of tokens to predict when generating text.
  NB Ollama uses "num_predict", but most executors are llama.cpp-based, and that uses "n_predict".
  - Default: **128**
  - -1 = infinite generation
  - -2 = fill context)

- `num_ctx`: Sets the size of the context window used to generate the next token.
  - Default: **2048**
"""

    @router.post("/generate.raw-templated")
    async def generate_raw_templated(
            templated_text: TemplatedPromptText,
            model_name: OllamaModelName = "llama3-8b-instruct:Q8_0",
            options_json: Annotated[str, Query(description=ollama_api_options_str)] \
                    = """{"num_predict":8192, "top_k": 80, "num_ctx": 16384}""",
            allow_streaming: bool = False,
            history_db: HistoryDB = Depends(get_history_db),
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        content = {
            'images': [],
            'model': model_name,
            'prompt': templated_text,
            'raw': True,
            'stream': True,
            # TODO: These options should be stored in the ModelConfigRecord,
            #       that was the whole point of that class.
            'options': orjson.loads(options_json),
        }

        headers = starlette.datastructures.MutableHeaders()
        headers['content-type'] = 'application/json'

        streaming_response = await do_generate_raw_templated(
            content,
            headers,
            None,
            history_db,
            ratelimits_db,
        )

        if allow_streaming:
            logging_aiter = chunk_and_log_output(
                streaming_response.body_iterator,
                lambda s: logger.debug("/generate.raw-templated: " + s),
            )
            streaming_response.body_iterator = logging_aiter
            return streaming_response

        else:
            async def content_to_json_adapter() -> OllamaResponseContentJSON:
                async def jsonner() -> AsyncIterable[OllamaResponseContentJSON]:
                    async for chunk in streaming_response.body_iterator:
                        yield orjson.loads(chunk)

                return await consolidate_stream(jsonner())

            return JSONResponse(
                content=await content_to_json_adapter(),
                status_code=streaming_response.status_code,
                headers=streaming_response.headers,
                background=streaming_response.background,
            )

    @router.post("/generate.raw", description="""\
This allows for easy-ish overriding of the assistant prompt,
which bypasses censoring for most models.""")
    async def generate_raw(
            user_message: str | None = None,
            system_message: str | None = None,
            assistant_prefix: str | None = None,
            model_name: OllamaModelName = "llama3-8b-instruct:Q8_0",
            options_json: Annotated[str, Query(description=ollama_api_options_str)] \
                    = """{"num_predict":8192, "top_k": 80, "num_ctx": 16384}""",
            history_db: HistoryDB = Depends(get_history_db),
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        model, executor_record = await lookup_model_offline(
            model_name,
            history_db,
        )

        model_template = safe_get(model.default_inference_params, 'template') or ''
        default_system_message = safe_get(model.default_inference_params, 'system') or ''

        templated_text = await apply_llm_template(
            model_template,
            system_message or default_system_message,
            user_message,
            assistant_prefix or '',
            assistant_prefix is not None,
        )

        content = {
            'images': [],
            'model': model_name,
            'prompt': templated_text,
            'raw': True,
            'stream': False,
            'options': orjson.loads(options_json),
        }
        headers = starlette.datastructures.MutableHeaders()
        headers['content-type'] = 'application/json'

        return await do_generate_raw_templated(
            content,
            headers,
            None,
            history_db,
            ratelimits_db,
        )

    app.include_router(router, prefix="/ollama")


def install_forwards(app: FastAPI, enable_rag: bool):
    ollama_forwarder = APIRouter()

    @ollama_forwarder.post("/ollama-proxy/api/generate")
    async def proxy_generate(
            request: Request,
            history_db: HistoryDB = Depends(get_history_db),
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        return await do_proxy_generate(request, history_db, ratelimits_db)

    @ollama_forwarder.post("/ollama-proxy/api/chat")
    async def proxy_chat_rag(
            request: Request,
            history_db: HistoryDB = Depends(get_history_db),
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
            knowledge: KnowledgeSingleton = Depends(get_knowledge_dependency),
    ):
        logger.debug(f"Received /api/chat request, starting processing")

        retrieval_policy = SkipRetrievalPolicy()
        if enable_rag:
            retrieval_policy = CustomRetrievalPolicy(knowledge)

        return await do_proxy_chat_rag(request, retrieval_policy, history_db, ratelimits_db)

    # TODO: Using a router prefix breaks this, somehow
    @ollama_forwarder.head("/ollama-proxy/{ollama_head_path:path}")
    async def proxy_head(
            request: Request,
            ollama_head_path,
    ):
        return await forward_request_nolog(ollama_head_path, request)

    @ollama_forwarder.get("/ollama-proxy/{ollama_get_path:path}")
    @ollama_forwarder.post("/ollama-proxy/{ollama_post_path:path}")
    async def proxy_get_post(
            request: Request,
            ollama_get_path: str | None = None,
            ollama_post_path: str | None = None,
            history_db: HistoryDB = Depends(get_history_db),
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        if ollama_get_path == "api/tags":
            return await do_api_tags(request, history_db, ratelimits_db)

        if ollama_post_path == "api/show":
            # TODO: Remove this log inhibitor once we've switched to a client that doesn't spam /api/show on startup
            with disable_info_logs("httpx", "history.ollama.model_routes"):
                return await do_api_show(request, history_db, ratelimits_db)

        return await forward_request(request, ratelimits_db)

    app.include_router(ollama_forwarder)