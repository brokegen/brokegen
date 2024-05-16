import logging
import re
from typing import Tuple, Any, AsyncIterator

import orjson
from starlette.background import BackgroundTask
from starlette.requests import Request
from starlette.responses import StreamingResponse

from access.ratelimits import RatelimitsDB, RequestInterceptor
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
        # TODO: This… wouldn't work, because the request content probably doesn't actually include the model
        await do_api_show(parent_request, history_db, ratelimits_db)
        model = fetch_model_record(executor_record, model_name, history_db)

        if not model:
            raise RuntimeError(f"Failed to fetch Ollama model {model_name}")

    return model, executor_record


async def construct_raw_prompt(
        model_template: str,
        system_message: str,
        user_prompt: str,
        assistant_response: str,
        break_early_on_response: bool = False,
) -> str | None:
    # Use the world's most terrible regexes to parse the Ollama template format
    template1 = model_template
    try:
        if_pattern = r'{{-?\s*if\s+(\.[^\s]+)\s*}}(.*?){{-?\s*end\s*}}'
        while True:
            match = next(re.finditer(if_pattern, template1, re.DOTALL))
            if_match, block = match.groups()

            if system_message and if_match == '.System':
                substituted_block = block
            elif user_prompt and if_match == '.Prompt':
                substituted_block = block
            elif assistant_response and if_match == '.Response':
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

            if system_message and real_match == '.System':
                substituted_block = system_message
            elif user_prompt and real_match == '.Prompt':
                substituted_block = user_prompt
            elif real_match == '.Response':
                if break_early_on_response:
                    # Actually, we should just plain exit right after this match.
                    template3 = template3[:match.start()]
                    break
                else:
                    substituted_block = assistant_response
            else:
                substituted_block = ''

            template3 = re.sub(real_pattern, lambda m: substituted_block, template3, count=1, flags=re.DOTALL)

    except StopIteration:
        pass

    return template3


async def do_proxy_generate(
        original_request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
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
        constructed_prompt = await construct_raw_prompt(
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
    intercept.build_access_event(upstream_response, api_bucket=f"ollama:/api/generate")
    intercept._set_or_delete_request_content(request_content_json)

    async def on_done(consolidated_response_content_json):
        response_stats = dict(consolidated_response_content_json)
        done = safe_get(response_stats, 'done')
        if not done:
            logger.warning(f"/api/generate ran out of bytes to process, but Ollama JSON response is {done=}")

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
