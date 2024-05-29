import logging
from datetime import datetime, timezone
from typing import Optional

import fastapi.routing
import orjson
import starlette.requests
from fastapi import Depends
from pydantic import BaseModel
from sqlalchemy import select

import history.ollama
from _util.json import JSONStreamingResponse, safe_get
from _util.typing import ChatSequenceID, InferenceModelRecordID
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from history.chat.database import ChatMessageOrm, ChatSequence, lookup_chat_message, ChatMessage, \
    lookup_sequence_parents
from history.chat.sequence_get import do_get_sequence
from history.ollama.chat_rag_routes import finalize_inference_job
from history.ollama.json import consolidate_stream_sync
from inference.embeddings.retrieval import SkipRetrievalPolicy
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm, InferenceEventOrm

logger = logging.getLogger(__name__)


class ExtendRequest(BaseModel):
    next_message: ChatMessage
    continuation_model_id: Optional[InferenceModelRecordID] = None


def select_continuation_model(
        sequence_id: ChatSequenceID | None,
        requested_model_id: InferenceModelRecordID | None,
        history_db: HistoryDB,
) -> InferenceEventOrm | None:
    if requested_model_id is not None:
        # TODO: Take this opportunity to confirm the InferenceModel is online.
        #       Though, maybe the inference events later on should be robust enough to handle errors.
        return history_db.execute(
            select(InferenceModelRecordOrm)
            .where(InferenceModelRecordOrm.id == requested_model_id)
        ).scalar_one()

    # Iterate over all sequence nodes until we find enough model info.
    # (ChatSequences can be missing inference_job_ids if they're user prompts, or errored out)
    for sequence in lookup_sequence_parents(sequence_id, history_db):
        if sequence.inference_job_id is None:
            continue

        inference_model: InferenceModelRecordOrm = history_db.execute(
            select(InferenceModelRecordOrm)
            .join(InferenceEventOrm, InferenceEventOrm.model_record_id == InferenceModelRecordOrm.id)
            .where(InferenceEventOrm.id == sequence.inference_job_id)
        ).scalar_one()

        return inference_model

    return None


async def do_continuation(
        messages_list: list[ChatMessageOrm],
        original_sequence: ChatSequence,
        inference_model: InferenceModelRecordOrm,
        empty_request: starlette.requests.Request,
        history_db: HistoryDB,
        audit_db: AuditDB,
):
    constructed_ollama_body = {
        "messages": [m.as_json() for m in messages_list],
        "model": inference_model.human_id,
    }

    # Manually construct a Request object, because that's how we pass any data around
    constructed_request = empty_request
    # NB This overwrites the internals of the Requests object;
    # we should really be passing decoded versions throughout the app.
    constructed_request._body = orjson.dumps(constructed_ollama_body)

    # Wrap the output in a… something that appends new ChatSequence information
    response_sequence = ChatSequence(
        human_desc=original_sequence.human_desc,
        parent_sequence=original_sequence.id,
    )

    async def construct_response_sequence(response_content_json):
        nonlocal inference_model
        inference_model = history_db.merge(inference_model)

        inference_job = InferenceEventOrm(
            model_record_id=inference_model.id,
            reason="chat sequence",
        )

        finalize_inference_job(inference_job, response_content_json)
        history_db.add(inference_job)

        assistant_response = ChatMessageOrm(
            role="assistant",
            content=safe_get(response_content_json, "message", "content"),
            created_at=inference_job.response_created_at,
        )
        history_db.add(assistant_response)
        history_db.commit()

        # Add what we need for response_sequence
        original_sequence.user_pinned = False
        response_sequence.user_pinned = True

        history_db.add(original_sequence)
        history_db.add(response_sequence)

        response_sequence.current_message = assistant_response.id

        response_sequence.generated_at = inference_job.response_created_at
        response_sequence.generation_complete = response_content_json["done"]
        response_sequence.inference_job_id = inference_job.id
        response_sequence.inference_error = (
            "this is a duplicate InferenceEvent, because do_generate_raw_templated will dump its own raws in. "
            "we're keeping this one because it's tied into the actual ChatSequence."
        )

        history_db.add(response_sequence)
        history_db.commit()

        return {
            "new_sequence_id": response_sequence.id,
            "done": True,
        }

    async def add_json_suffix(primordial):
        all_chunks = []

        done_signaled: int = 0
        async for chunk in primordial:
            try:
                chunk_json = orjson.loads(chunk)
                if chunk_json["done"]:
                    done_signaled += 1
                    chunk_json["done"] = False
                    yield orjson.dumps(chunk_json)
                    all_chunks.append(chunk)
                    continue
            except Exception:
                logger.exception(f"/chat: Response decode to JSON failed, {len(all_chunks)=}")

            yield chunk
            all_chunks.append(chunk)
            if done_signaled > 0:
                logger.warning(f"/chat: Still yielding chunks after `done=True`")

        if not done_signaled:
            logger.warning(f"/chat: Finished streaming response without hitting `done=True`")

        # Construct our actual suffix
        consolidated_response = await consolidate_stream_sync(all_chunks, logger.warning)
        suffix_chunk = orjson.dumps(await construct_response_sequence(consolidated_response))
        yield suffix_chunk

    async def wrap_response(
            upstream_response: JSONStreamingResponse,
    ) -> JSONStreamingResponse:
        upstream_response._content_iterable = add_json_suffix(upstream_response._content_iterable)
        return upstream_response

    return await wrap_response(
        await history.ollama.chat_rag_routes.do_proxy_chat_rag(
            constructed_request,
            SkipRetrievalPolicy(),
            history_db,
            audit_db,
        ))


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post("/sequences/{sequence_id:int}/continue")
    async def sequence_continue(
            empty_request: starlette.requests.Request,
            sequence_id: ChatSequenceID,
            continuation_model_id: InferenceModelRecordID | None = None,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ) -> JSONStreamingResponse:
        original_sequence = history_db.execute(
            select(ChatSequence)
            .filter_by(id=sequence_id)
        ).scalar_one()

        messages_list: list[ChatMessageOrm] = \
            do_get_sequence(sequence_id, history_db, include_model_info_diffs=False)

        # Decide how to continue inference for this sequence
        inference_model: InferenceModelRecordOrm = \
            select_continuation_model(sequence_id, continuation_model_id, history_db)

        return await do_continuation(
            messages_list,
            original_sequence,
            inference_model,
            empty_request,
            history_db,
            audit_db,
        )

    @router_ish.post("/sequences/{sequence_id:int}/extend")
    async def sequence_extend(
            empty_request: starlette.requests.Request,
            sequence_id: ChatSequenceID,
            params: ExtendRequest,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ) -> JSONStreamingResponse:
        # Manually fetch the message + model config history from our requests
        messages_list: list[ChatMessageOrm] = \
            do_get_sequence(sequence_id, history_db, include_model_info_diffs=False)

        # First, store the message that was painstakingly generated for us.
        original_sequence = history_db.execute(
            select(ChatSequence)
            .filter_by(id=sequence_id)
        ).scalar_one()

        user_sequence = ChatSequence(
            human_desc=original_sequence.human_desc,
            parent_sequence=original_sequence.id,
            generated_at=datetime.now(tz=timezone.utc),
            generation_complete=False,
        )

        maybe_message = lookup_chat_message(params.next_message, history_db)
        if maybe_message is not None:
            messages_list.append(maybe_message)
            user_sequence.current_message = maybe_message.id
            user_sequence.generation_complete = True
        else:
            new_message = ChatMessageOrm(**params.next_message.model_dump())
            history_db.add(new_message)
            history_db.commit()
            messages_list.append(new_message)
            user_sequence.current_message = new_message.id
            user_sequence.generation_complete = True

        # Mark this user response as the current up-to-date
        user_sequence.user_pinned = original_sequence.user_pinned
        original_sequence.user_pinned = False

        history_db.add(original_sequence)
        history_db.add(user_sequence)
        history_db.commit()

        # Decide how to continue inference for this sequence
        inference_model: InferenceModelRecordOrm = \
            select_continuation_model(sequence_id, params.continuation_model_id, history_db)

        return await do_continuation(
            messages_list,
            original_sequence if user_sequence.id is None else user_sequence,
            inference_model,
            empty_request,
            history_db,
            audit_db,
        )
