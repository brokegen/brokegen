import logging
from datetime import datetime, timezone
from typing import TypeAlias, Union

from _util.json import JSONDict, safe_get
from _util.typing import PromptText
from client.database import HistoryDB
from client.message import ChatMessageOrm
from client.sequence import ChatSequenceOrm
from providers.foundation_models.orm import InferenceEventOrm

logger = logging.getLogger(__name__)

OllamaRequestContentJSON: TypeAlias = JSONDict
OllamaResponseContentJSON: TypeAlias = JSONDict

OllamaChatResponse: TypeAlias = JSONDict
"""Result of /api/chat, expected to store its message content in $0.message.content"""
OllamaGenerateResponse: TypeAlias = JSONDict
"""Result of /api/generate, content will be in $0.response"""

OllamaResponseChunk: TypeAlias = Union[OllamaChatResponse, OllamaGenerateResponse]


def finalize_inference_job(
        inference_event: InferenceEventOrm,
        response_content: OllamaResponseChunk,
) -> None:
    logger.debug(f"Finalizing InferenceEvent {inference_event.id} with {response_content.keys()=}")

    if safe_get(response_content, 'prompt_eval_count'):
        inference_event.prompt_tokens = safe_get(response_content, 'prompt_eval_count')
    if safe_get(response_content, 'prompt_eval_duration'):
        inference_event.prompt_eval_time = safe_get(response_content, 'prompt_eval_duration') / 1e9

    if safe_get(response_content, 'created_at'):
        inference_event.response_created_at = \
            datetime.fromisoformat(safe_get(response_content, 'created_at')) \
            or datetime.now(tz=timezone.utc)
    if safe_get(response_content, 'eval_count'):
        inference_event.response_tokens = safe_get(response_content, 'eval_count')
    if safe_get(response_content, 'eval_duration'):
        inference_event.response_eval_time = safe_get(response_content, 'eval_duration') / 1e9

    # TODO: I'm not sure this is even the actual field to check
    if safe_get(response_content, 'error'):
        inference_event.response_error = safe_get(response_content, 'error')
    else:
        inference_event.response_error = None

    inference_event.response_info = dict(response_content)


def ollama_log_indexer(
        chunk_json: OllamaResponseChunk,
) -> PromptText:
    # /api/generate returns in the first form
    # /api/chat returns the second form, with 'role': 'user'
    return safe_get(chunk_json, 'response') \
        or safe_get(chunk_json, 'message', 'content') \
        or ""


async def construct_new_sequence_from(
        original_sequence: ChatSequenceOrm,
        assistant_response_seed: PromptText | None,
        consolidated_response: OllamaResponseContentJSON,
        inference_event: InferenceEventOrm,
        history_db: HistoryDB,
) -> tuple[ChatSequenceOrm, ChatMessageOrm] | None:
    assistant_message = ChatMessageOrm(
        role="assistant",
        content=(assistant_response_seed or "") + ollama_log_indexer(consolidated_response),
        created_at=inference_event.response_created_at,
    )
    if not assistant_message.content:
        return None

    history_db.add(assistant_message)
    history_db.commit()

    # Add what we need for response_sequence
    response_sequence = ChatSequenceOrm(
        human_desc=original_sequence.human_desc,
        current_message=assistant_message.id,
        parent_sequence=original_sequence.id,
    )

    response_sequence.user_pinned = original_sequence.user_pinned
    original_sequence.user_pinned = False

    history_db.add(original_sequence)
    history_db.add(response_sequence)

    response_sequence.generated_at = inference_event.response_created_at
    response_sequence.generation_complete = True
    response_sequence.inference_job_id = inference_event.id
    if inference_event.response_error:
        response_sequence.inference_error = inference_event.response_error

    history_db.commit()

    # And complete the circular reference that really should be handled in the SQLAlchemy ORM
    inference_job = history_db.merge(inference_event)
    inference_job.parent_sequence = response_sequence.id

    history_db.add(inference_job)
    history_db.commit()

    if not safe_get(consolidated_response, 'done'):
        logger.debug(f"Generated ChatSequence#{response_sequence.id}, but response was marked not-done")

    return response_sequence, assistant_message


def ollama_response_consolidator(
        chunk: OllamaResponseChunk,
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
