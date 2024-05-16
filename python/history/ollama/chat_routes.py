import logging
import re
from typing import Tuple, Any

import orjson
from starlette.background import BackgroundTask
from starlette.requests import Request
from starlette.responses import StreamingResponse

from access.ratelimits import RatelimitsDB, PlainRequestInterceptor
from history.database import HistoryDB, InferenceJob, ModelConfigRecord, ExecutorConfigRecord
from history.ollama.forward_routes import _real_ollama_client
from history.ollama.model_routes import do_api_show
from history.ollama.models import build_executor_record, fetch_model_record

logger = logging.getLogger(__name__)


def safe_get(
        dict_like: Any | None,
        *keys: Any,
) -> Any | dict:
    """
    Returns empty dict if any of the keys failed to appear.
    Only handles dicts, no lists.
    """
    if dict_like is None:
        return {}

    for key in keys:
        if key in dict_like:
            dict_like = dict_like[key]
        else:
            return {}

    return dict_like


async def lookup_model(
        parent_request: Request,
        model_name: str,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
) -> Tuple[ModelConfigRecord, ExecutorConfigRecord]:
    executor_record = build_executor_record(str(_real_ollama_client.base_url), history_db=history_db)
    model = fetch_model_record(executor_record, model_name, history_db)

    if not model:
        await do_api_show(parent_request, history_db, ratelimits_db)
        model = fetch_model_record(executor_record, model_name, history_db)

        if not model:
            raise RuntimeError(f"Failed to fetch Ollama model {model_name}")

    return model, executor_record


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
    if_pattern = r'{{-?\s*if\s+(\.[^\s]+)\s*}}(.*?){{-?\s*end\s*}}'
    matches1 = re.finditer(if_pattern, template0, re.DOTALL)

    template1 = template0
    for match in matches1:
        if_match, block = match.groups()

        if system_str and if_match == '.System':
            substituted_block = block
        elif plain_prompt and if_match == '.Prompt':
            substituted_block = block
        else:
            substituted_block = ''

        template1 = re.sub(if_pattern, lambda m: substituted_block, template1, count=1, flags=re.DOTALL)

    real_pattern = r'{{\s*(\.[^\s]+?)\s*\}}'
    matches2 = re.finditer(real_pattern, template1, re.DOTALL)

    template2 = template1
    for match in matches2:
        (real_match,) = match.groups()

        if system_str and real_match == '.System':
            substituted_block = system_str
        elif plain_prompt and real_match == '.Prompt':
            substituted_block = plain_prompt

            # Actually, we should just plain exit right after this match.
            template2 = template2[:match.start()]
            break

        else:
            substituted_block = ''

        template2 = re.sub(real_pattern, lambda m: substituted_block, template2, count=1, flags=re.DOTALL)

    inference_job.raw_prompt = template2
    return template2


async def do_proxy_generate(
        original_request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
):
    intercept = PlainRequestInterceptor(logger, ratelimits_db)

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
            request_content_json['prompt'],
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
        url="/api/generate",
        content=orjson.dumps(request_content_json),
        headers=modified_headers,
        cookies=original_request.cookies,
    )

    upstream_response = await _real_ollama_client.send(upstream_request, stream=True)
    intercept.build_access_event(upstream_response, api_bucket=f"ollama:/api/generate")
    # NB We have to a do a full dict copy. For some reason.
    new_request_dict = dict(intercept.new_access.request)
    new_request_dict['content'] = request_content_json
    intercept.new_access.request = new_request_dict

    async def on_done(consolidated_response_content_json):
        response_stats = dict(consolidated_response_content_json)
        if safe_get(response_stats, 'done'):
            logger.warning(f"/api/generate said it was done, but response is marked incomplete")

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

        # NB We have to a do a full dict copy. For some reason.
        new_response_json = dict(intercept.new_access.response)
        new_response_json['content'] = as_json
        intercept.new_access.response = new_response_json

        ratelimits_db.add(intercept.new_access)
        ratelimits_db.commit()

        await on_done(as_json[-1])

    return StreamingResponse(
        content=intercept.wrap_response_content_raw(upstream_response.aiter_raw()),
        status_code=upstream_response.status_code,
        headers=upstream_response.headers,
        background=BackgroundTask(post_forward_cleanup),
    )
