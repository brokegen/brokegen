import logging
from typing import Tuple

import orjson
from starlette.requests import Request

from audit.http import AuditDB
from history.ollama.json import OllamaEventBuilder
from history.ollama.model_routes import do_api_show
from history.ollama.models import fetch_model_record
from history.shared.json import safe_get
from inference.prompting.templating import apply_llm_template
from providers.database import HistoryDB, InferenceEvent, ModelConfigRecord, ProviderRecordOrm
from providers.ollama import _real_ollama_client, build_executor_record

logger = logging.getLogger(__name__)


async def lookup_model_offline(
        model_name: str,
        history_db: HistoryDB,
) -> Tuple[ModelConfigRecord, ProviderRecordOrm]:
    # TODO: Standardize on verb names, e.g. lookup for offline + fetch for maybe-online
    executor_record = build_executor_record(
        str(_real_ollama_client.base_url),
        history_db=history_db)
    model = fetch_model_record(
        executor_record,
        model_name,
        history_db)
    if model is None:
        raise ValueError(f"Model not in database: {model_name}")

    return model, executor_record


async def lookup_model(
        parent_request: Request,
        model_name: str,
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> Tuple[ModelConfigRecord, ProviderRecordOrm]:
    try:
        model, executor_record = lookup_model_offline(model_name, history_db)

    except ValueError:
        executor_record = build_executor_record(
            str(_real_ollama_client.base_url),
            history_db=history_db)

        # TODO: This… wouldn't work, because the request content probably doesn't actually include the model
        await do_api_show(parent_request, history_db, audit_db)
        model = fetch_model_record(executor_record, model_name, history_db)

        if not model:
            raise RuntimeError(f"Failed to fetch Ollama model {model_name}")

    return model, executor_record


async def do_proxy_generate(
        original_request: Request,
        history_db: HistoryDB,
        audit_db: AuditDB,
):
    intercept = OllamaEventBuilder("ollama:/api/generate", audit_db)

    request_content_bytes: bytes = await original_request.body()
    request_content_json: dict = orjson.loads(request_content_bytes)
    intercept.wrapped_event.request_info = request_content_json
    intercept._try_commit()

    model, executor_record = await lookup_model(original_request, request_content_json['model'], history_db,
                                                audit_db)

    inference_job = InferenceEvent(
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

    try:
        constructed_prompt = await apply_llm_template(
            model_template,
            system_message,
            safe_get(request_content_json, 'prompt'),
            assistant_response='',
        )
        inference_job.raw_prompt = constructed_prompt
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
        url="/api/generate",
        content=orjson.dumps(request_content_json),
        headers=modified_headers,
        cookies=original_request.cookies,
    )

    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)
    return intercept.wrap_entire_streaming_response(upstream_response)
