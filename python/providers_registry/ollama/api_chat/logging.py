import logging
from datetime import datetime

from _util.json import JSONDict, safe_get
from client.chat_message import ChatMessageOrm
from client.chat_sequence import ChatSequence
from client.database import HistoryDB
from providers.inference_models.orm import InferenceEventOrm, InferenceModelRecordOrm
from providers_registry.ollama.json import OllamaResponseContentJSON

logger = logging.getLogger(__name__)


def finalize_inference_job(
        inference_job: InferenceEventOrm,
        response_content_json: OllamaResponseContentJSON,
) -> None:
    if safe_get(response_content_json, 'prompt_eval_count'):
        inference_job.prompt_tokens = safe_get(response_content_json, 'prompt_eval_count')
    if safe_get(response_content_json, 'prompt_eval_duration'):
        inference_job.prompt_eval_time = safe_get(response_content_json, 'prompt_eval_duration') / 1e9

    if safe_get(response_content_json, 'created_at'):
        inference_job.response_created_at = datetime.fromisoformat(safe_get(response_content_json, 'created_at'))
    if safe_get(response_content_json, 'eval_count'):
        inference_job.response_tokens = safe_get(response_content_json, 'eval_count')
    if safe_get(response_content_json, 'eval_duration'):
        inference_job.response_eval_time = safe_get(response_content_json, 'eval_duration') / 1e9

    # TODO: I'm not sure this is even the actual field to check
    if safe_get(response_content_json, 'error'):
        inference_job.response_error = safe_get(response_content_json, 'error')
    else:
        inference_job.response_error = None

    inference_job.response_info = dict(response_content_json)


async def inference_event_logger(
        consolidated_response: OllamaResponseContentJSON,
        inference_model: InferenceModelRecordOrm,
        history_db: HistoryDB,
) -> InferenceEventOrm:
    inference_event = InferenceEventOrm(
        model_record_id=inference_model.id,
        reason="chat sequence",
        response_error="[haven't received/finalized response info yet]",
    )

    finalize_inference_job(inference_event, consolidated_response)
    history_db.add(inference_event)
    history_db.commit()

    return inference_event


async def construct_new_sequence_from(
        original_sequence: ChatSequence,
        consolidated_response: OllamaResponseContentJSON,
        inference_event: InferenceEventOrm,
        history_db: HistoryDB,
) -> ChatSequence:
    # Wrap the output in a… something that appends new ChatSequence information
    response_sequence = ChatSequence(
        human_desc=original_sequence.human_desc,
        parent_sequence=original_sequence.id,
    )

    assistant_response = ChatMessageOrm(
        role="assistant",
        content=safe_get(consolidated_response, "message", "content"),
        created_at=inference_event.response_created_at,
    )
    history_db.add(assistant_response)
    history_db.commit()

    # Add what we need for response_sequence
    original_sequence.user_pinned = False
    response_sequence.user_pinned = True

    history_db.add(original_sequence)
    history_db.add(response_sequence)

    response_sequence.current_message = assistant_response.id

    response_sequence.generated_at = inference_event.response_created_at
    response_sequence.generation_complete = consolidated_response["done"]
    response_sequence.inference_job_id = inference_event.id
    if inference_event.response_error:
        response_sequence.inference_error = inference_event.response_error

    history_db.add(response_sequence)
    history_db.commit()

    # And complete the circular reference that really should be handled in the SQLAlchemy ORM
    inference_job = history_db.merge(inference_event)
    inference_job.parent_sequence = response_sequence.id

    # TODO: This is disabled while we figure out why the duplicate InferenceEvent never commits its response content
    if False and not inference_job.response_error:
        inference_job.response_error = (
            "this is a duplicate InferenceEvent, because do_generate_raw_templated will dump its own raws in. "
            "we're keeping this one because it's tied into the actual ChatSequence."
        )

    history_db.add(inference_job)
    history_db.commit()

    return response_sequence


def ollama_log_indexer(
        chunk_json: JSONDict,
) -> str:
    return safe_get(chunk_json, 'message', 'content') or ""


def ollama_response_consolidator(
        chunk: JSONDict,
        consolidated_response: OllamaResponseContentJSON,
) -> OllamaResponseContentJSON:
    if not consolidated_response:
        return chunk

    for k, v in chunk.items():
        if k not in consolidated_response:
            consolidated_response[k] = v
            continue

        if k == 'created_at':
            consolidated_response['terminal_created_at'] = v
            continue

        elif k == 'done':
            if consolidated_response[k]:
                logger.warning(f"Received additional JSON after streaming indicated we were {k}={v}")

        elif k == 'model':
            if consolidated_response[k] != v:
                raise ValueError(
                    f"Received new model name \"{v}\" during streaming response, expected {consolidated_response[k]}")

        # This tends to be the output from /api/generate
        elif k == 'response':
            consolidated_response[k] += v
            continue

        # And this is /api/chat, which we don't care too much about.
        # Except as a stopgap, for now.
        elif k == 'message':
            if set(v.keys()) != {'content', 'role'}:
                logger.warning(f"Received unexpected message content with keys: {v.keys()}")
            if v['role'] != 'assistant':
                logger.warning(f"Received content for unexpected role \"{v['role']}\", continuing anyway")

            consolidated_response[k]['content'] += v['content']
            continue

        else:
            raise ValueError(
                f"Received unidentified JSON pair {k}={v}, abandoning consolidation of JSON blobs.\n"
                f"Current consolidated response has key set: {consolidated_response.keys()}")

        # In the non-exceptional case, just update with the new value.
        consolidated_response[k] = v

    return consolidated_response
