import logging
from typing import Tuple

import orjson
from starlette.requests import Request

from access.ratelimits import RatelimitsDB
from history.database import HistoryDB, InferenceJob, ModelConfigRecord, ExecutorConfigRecord
from history.ollama.forward_routes import forward_request, _real_ollama_client
from history.ollama.model_routes import do_api_show
from history.ollama.models import build_executor_record, fetch_model_record

logger = logging.getLogger(__name__)


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


async def do_proxy_generate(
        request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
):
    logger.info(f"Intercepting a generate request: {request}")

    request_content_json: dict = orjson.loads(await request.body())
    model, executor_record = await lookup_model(request, request_content_json['model'], history_db, ratelimits_db)

    inference_job = InferenceJob(
        model_config=model.id,
        overridden_inference_params=request_content_json.get('options', None),
    )
    history_db.add(inference_job)
    history_db.commit()

    async def on_done(consolidated_response_content_json):
        response_stats = dict(consolidated_response_content_json)
        if not response_stats['done']:
            logger.warning(f"/api/generate said it was done, but response is marked incomplete")

        # Ollama /api/generate endpoints sometimes respond with a giant list of ints for "context",
        # which somewhat removes the need to provide complete chat history.
        if 'context' in response_stats:
            del response_stats['context']

        # The "response" doesn't go in stats.
        del response_stats['response']

        merged_job = history_db.merge(inference_job)
        merged_job.response_stats = response_stats
        history_db.add(merged_job)
        history_db.commit()

        # TODO: Now add/create the two messages that happened

    return await forward_request(request, ratelimits_db, on_done)
