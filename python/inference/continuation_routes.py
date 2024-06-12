import logging
from datetime import datetime, timezone

import fastapi.routing
import starlette.datastructures
import starlette.datastructures
import starlette.requests
import starlette.requests
from fastapi import Depends, HTTPException
from sqlalchemy import select

from _util.json_streaming import JSONStreamingResponse
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from client.database import ChatMessageOrm, ChatSequence, lookup_chat_message, ChatMessage
from client.sequence_get import do_get_sequence
from inference.continuation import ContinueRequest, ExtendRequest, select_continuation_model
from retrieval.embeddings.retrieval import RetrievalLabel
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm

logger = logging.getLogger(__name__)


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post("/v2/sequences/{sequence_id:int}/continue")
    async def sequence_continue(
            empty_request: starlette.requests.Request,
            sequence_id: ChatSequenceID,
            params: ContinueRequest,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ) -> JSONStreamingResponse:
        original_sequence = history_db.execute(
            select(ChatSequence)
            .filter_by(id=sequence_id)
        ).scalar_one()

        messages_list: list[ChatMessage] = \
            do_get_sequence(sequence_id, history_db, include_model_info_diffs=False)

        # Decide how to continue inference for this sequence
        inference_model: InferenceModelRecordOrm = \
            select_continuation_model(sequence_id, params.continuation_model_id, params.fallback_model_id, history_db)

        status_holder = ServerStatusHolder(
            f"/sequences/{sequence_id}/continue: processing on {inference_model.human_id}")

        # And RetrievalLabel
        retrieval_label = RetrievalLabel(
            retrieval_policy=params.retrieval_policy,
            retrieval_search_args=params.retrieval_search_args,
            preferred_embedding_model=params.preferred_embedding_model,
        )

        raise HTTPException(501)

    @router_ish.post("/v2/sequences/{sequence_id:int}/extend")
    async def sequence_extend(
            empty_request: starlette.requests.Request,
            sequence_id: ChatSequenceID,
            params: ExtendRequest,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ) -> JSONStreamingResponse:
        # Manually fetch the message + model config history from our requests
        messages_list: list[ChatMessage] = \
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
            messages_list.append(ChatMessage.from_orm(maybe_message))
            user_sequence.current_message = maybe_message.id
            user_sequence.generation_complete = True
        else:
            new_message = ChatMessageOrm(**params.next_message.model_dump())
            history_db.add(new_message)
            history_db.commit()
            messages_list.append(ChatMessage.from_orm(new_message))
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
            select_continuation_model(sequence_id, params.continuation_model_id, params.fallback_model_id, history_db)

        status_holder = ServerStatusHolder(
            f"/sequences/{sequence_id}/extend: processing on {inference_model.human_id}")

        # And RetrievalLabel
        retrieval_label = RetrievalLabel(
            retrieval_policy=params.retrieval_policy,
            retrieval_search_args=params.retrieval_search_args,
            preferred_embedding_model=params.preferred_embedding_model,
        )

        raise HTTPException(501)
