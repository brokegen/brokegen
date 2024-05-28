import logging
from datetime import datetime, timezone

import fastapi.routing
import orjson
import starlette.requests
from fastapi import Depends
from pydantic import BaseModel
from sqlalchemy import select

import history.ollama
from _util.json import JSONStreamingResponse
from _util.typing import ChatSequenceID, PromptText, InferenceModelHumanID, ChatMessageID
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from history.chat.database import ChatMessageOrm, ChatSequence, lookup_chat_message, ChatMessageAddRequest
from history.chat.routes_sequence import do_get_sequence
from inference.embeddings.retrieval import SkipRetrievalPolicy
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm, InferenceEventOrm, InferenceEventID

logger = logging.getLogger(__name__)


class GenerateIn(BaseModel):
    user_prompt: PromptText
    sequence_id: ChatSequenceID


def construct_router():
    router = fastapi.routing.APIRouter()

    @router.post("/generate")
    async def get_simple_chat(
            empty_request: starlette.requests.Request,
            params: GenerateIn,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ) -> JSONStreamingResponse:
        original_sequence = history_db.execute(
            select(ChatSequence)
            .filter_by(id=params.sequence_id)
        ).scalar_one()

        # Manually fetch the message + model config history from our requests
        messages_list: list[ChatMessageOrm] = \
            do_get_sequence(params.sequence_id, history_db, include_model_info_diffs=False)

        # First, store the message that was painstakingly generated for us.
        user_sequence = ChatSequence(
            human_desc=original_sequence.human_desc,
            parent_sequence=original_sequence.id,
            generated_at=datetime.now(tz=timezone.utc),
            generation_complete=False,
        )

        if params.user_prompt and params.user_prompt.strip():
            new_message = ChatMessageOrm(
                role='user',
                content=params.user_prompt,
                created_at=user_sequence.generated_at,
            )
            maybe_message = lookup_chat_message(ChatMessageAddRequest.from_orm(new_message), history_db)
            if maybe_message is not None:
                messages_list.append(maybe_message)
                user_sequence.current_message = maybe_message.id
                user_sequence.generation_complete = True
            else:
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

        # Fetch the InferenceModelHumanID from latest ChatSequence
        inference_id: InferenceEventID = history_db.execute(
            select(InferenceEventOrm.id)
            .join(ChatSequence, ChatSequence.inference_job_id == InferenceEventOrm.id)
            .where(ChatSequence.id == params.sequence_id)
        ).scalar_one()

        model_name: InferenceModelHumanID = history_db.execute(
            select(InferenceModelRecordOrm.human_id)
            .join(InferenceEventOrm, InferenceEventOrm.model_record_id == InferenceModelRecordOrm.id)
            .where(InferenceEventOrm.id == inference_id)
        ).scalar_one()

        constructed_ollama_body = {
            "messages": [m.as_json() for m in messages_list],
            "model": model_name,
        }

        # Manually construct a Request object, because that's how we pass any data around
        constructed_request = empty_request
        # NB This overwrites the internals of the Requests object;
        # we should really be passing decoded versions throughout the app.
        constructed_request._body = orjson.dumps(constructed_ollama_body)

        # Wrap the output in a… something that appends new ChatSequence information
        partial_response_sequence = ChatSequence(
            human_desc=original_sequence.human_desc,
            parent_sequence=user_sequence.id or original_sequence.id,
            generation_complete=False
        )

        async def add_json_suffix(primordial):
            done_signaled: int = 0
            async for chunk in primordial:
                chunk_json = orjson.loads(chunk)
                if chunk_json["done"]:
                    done_signaled += 1
                    chunk_json["done"] = False
                    yield orjson.dumps(chunk_json)
                    continue

                yield chunk
                if done_signaled > 0:
                    logger.warning(f"/generate: Still yielding chunks after `done=True`")

            if not done_signaled:
                logger.warning(f"Finished /generate streaming response without hitting `done=True`")

            # Construct our actual suffix
            suffix_chunk_json = {
                "new_sequence_id": -1,
                "error": "sequence id's not actually implemented",
            }
            yield orjson.dumps(suffix_chunk_json)

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

    return router
