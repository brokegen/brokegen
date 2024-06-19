import logging
from typing import Tuple

import orjson
from fastapi import HTTPException
from starlette.requests import Request

from _util.json import safe_get
from audit.http import AuditDB
from providers_registry.ollama.json import OllamaEventBuilder
from providers_registry.ollama.model_routes import do_api_show, _real_ollama_client
from inference.prompting.templating import apply_llm_template
from client.database import HistoryDB
from providers.inference_models.orm import InferenceModelRecordOrm, InferenceEventOrm, lookup_inference_model, \
    InferenceReason
from _util.typing import InferenceModelHumanID
from providers.orm import ProviderLabel, ProviderRecord
from providers.registry import ProviderRegistry

logger = logging.getLogger(__name__)


async def lookup_model_offline(
        model_name: InferenceModelHumanID,
        history_db: HistoryDB,
) -> Tuple[InferenceModelRecordOrm, ProviderRecord]:
    provider = await ProviderRegistry().try_make(ProviderLabel(type="ollama", id="http://localhost:11434"))
    if provider is None:
        raise HTTPException(500, "No Provider loaded")

    provider_record = await provider.make_record()
    model = lookup_inference_model(model_name, provider_record.identifiers, history_db)
    if not model:
        raise HTTPException(400, "Trying to look up model that doesn't exist, you should create it first")
    if not safe_get(model.combined_inference_parameters, 'template'):
        logger.error(f"No Ollama template info for {model.human_id}, fill it in with an /api/show proxy call")
        raise HTTPException(500, "No model template available, confirm that InferenceModelRecords are complete")

    return model, provider_record


async def lookup_model(
        model_name: InferenceModelHumanID,
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> Tuple[InferenceModelRecordOrm, ProviderRecord]:
    try:
        return await lookup_model_offline(model_name, history_db)
    except (ValueError, HTTPException):
        provider = ProviderRegistry().by_label[ProviderLabel(type="ollama", id=str(_real_ollama_client.base_url))]
        return await do_api_show(model_name, history_db, audit_db), await provider.make_record()


async def do_proxy_generate(
        original_request: Request,
        inference_reason: InferenceReason,
        history_db: HistoryDB,
        audit_db: AuditDB,
):
    intercept = OllamaEventBuilder("ollama:/api/generate", audit_db)

    request_content_bytes: bytes = await original_request.body()
    request_content_json: dict = orjson.loads(request_content_bytes)
    intercept.wrapped_event.request_info = request_content_json
    intercept._try_commit()

    model, executor_record = await lookup_model(request_content_json['model'], history_db, audit_db)

    inference_job = InferenceEventOrm(
        model_config=model.id,
        overridden_inference_params=request_content_json.get('options', None),
        reason=inference_reason,
    )
    history_db.add(inference_job)
    history_db.commit()

    # Tweak the request so we see/add the `raw` prompting info
    model_template = (
            safe_get(inference_job.overridden_inference_params, 'options', 'template')
            or safe_get(model.combined_inference_parameters, 'template')
            or ''
    )

    system_message = (
            safe_get(inference_job.overridden_inference_params, 'options', 'system')
            or safe_get(model.combined_inference_parameters, 'system')
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

    # https://github.com/encode/httpx/discussions/2959
    # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
    modified_headers['connection'] = 'close'

    if request_content_json['raw']:
        for unsupported_field in ['template', 'system', 'context']:
            if unsupported_field in request_content_json:
                del request_content_json[unsupported_field]

    upstream_request = _real_ollama_client.build_request(
        method='POST',
        url="/api/generate",
        content=orjson.dumps(intercept.wrap_request(request_content_json)),
        headers=modified_headers,
        cookies=original_request.cookies,
    )

    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)
    return intercept.wrap_entire_streaming_response(upstream_response)
