import logging
from typing import Annotated, AsyncIterable

import orjson
import starlette.datastructures
from fastapi import FastAPI, APIRouter, Query, Depends
from starlette.responses import JSONResponse

from _util.json import safe_get
from _util.typing import TemplatedPromptText
from audit.http import AuditDB, get_db as get_audit_db
from inference.prompting.templating import apply_llm_template
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers_ollama.chat_rag_util import OllamaModelName, do_generate_raw_templated
from providers_ollama.chat_routes import lookup_model_offline
from providers_ollama.json import chunk_and_log_output, OllamaResponseContentJSON, consolidate_stream

logger = logging.getLogger(__name__)


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
            model_name: OllamaModelName = "llama3-gradient:latest",
            options_json: Annotated[str, Query(description=ollama_api_options_str)] \
                    = """{"num_predict": 128, "top_k": 80, "num_ctx": 16384}""",
            allow_streaming: bool = True,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ):
        content = {
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
            audit_db,
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
which bypasses censoring for tested models.""")
    async def generate_raw(
            user_prompt: str | None = None,
            system_message: str | None = None,
            assistant_prefix: str | None = None,
            model_name: OllamaModelName = "llama3-gradient:latest",
            options_json: Annotated[str, Query(description=ollama_api_options_str)] \
                    = """{"num_predict": 8192, "top_k": 80, "num_ctx": 16384}""",
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ):
        model, executor_record = await lookup_model_offline(
            model_name,
            history_db,
        )

        model_template = safe_get(model.combined_inference_parameters, 'template') or ''
        default_system_message = safe_get(model.combined_inference_parameters, 'system') or ''

        templated_text = await apply_llm_template(
            model_template=model_template,
            system_message=system_message or default_system_message,
            user_prompt=user_prompt,
            assistant_response=assistant_prefix or '',
            break_early_on_response=assistant_prefix is not None,
        )

        content = {
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
            audit_db,
            inference_reason="[endpoint: /generate.raw]",
        )

    app.include_router(router, prefix="/ollama")
