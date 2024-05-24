import logging
from datetime import datetime
from http.client import HTTPException
from typing import Optional

import fastapi.routing
from fastapi import FastAPI, Depends
from pydantic import BaseModel
from sqlalchemy import select

from history.chat.database import MessageID, Message, ChatSequenceID, ChatSequence
from history.shared.database import HistoryDB, get_db as get_history_db
from history.shared.json import JSONDict
from inference.prompting.models import RoleName, PromptText

logger = logging.getLogger(__name__)


class SequenceIn(BaseModel):
    human_desc: Optional[str] = None
    user_pinned: Optional[bool] = None

    current_message: MessageID
    parent_sequence: Optional[ChatSequenceID] = None

    generated_at: Optional[datetime] = None
    generation_complete: bool
    inference_job_id: Optional[int] = None
    inference_error: Optional[str] = None


class SequenceAddResponse(BaseModel):
    sequence_id: ChatSequenceID
    just_created: bool


def install_routes(app: FastAPI):
    router = fastapi.routing.APIRouter()

    @router.post("/sequences")
    async def post_sequence(
            seq_in: SequenceIn,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> SequenceAddResponse:
        maybe_sequence_id = history_db.execute(
            select(ChatSequence.id)
            .filter_by(
                current_message=seq_in.current_message,
                parent_sequence=seq_in.parent_sequence,
            )
            .limit(1)
        ).scalar_one_or_none()
        if maybe_sequence_id:
            return SequenceAddResponse(
                sequence_id=maybe_sequence_id,
                just_created=False,
            )

        new_object = ChatSequence(
            human_desc=seq_in.human_desc,
            user_pinned=seq_in.user_pinned,
            current_message=seq_in.current_message,
            parent_sequence=seq_in.parent_sequence,
            generated_at=seq_in.generated_at,
            generation_complete=seq_in.generation_complete,
            inference_job_id=seq_in.inference_job_id,
            inference_error=seq_in.inference_error,
        )
        history_db.add(new_object)
        history_db.commit()

        return SequenceAddResponse(
            sequence_id=new_object.id,
            just_created=True,
        )

    @router.get("/sequences/{id:int}")
    def get_sequence(
            id: ChatSequenceID,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        match_object = history_db.execute(
            select(ChatSequence)
            .filter_by(id=id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(400, "No matching object")

        messages_list = []
        sequence_id: ChatSequenceID = id
        while sequence_id is not None:
            logger.debug(f"Checking for sequence {id} => ancestor {sequence_id}")
            message_row = history_db.execute(
                select(Message, ChatSequence.parent_sequence)
                .join(Message, Message.id == ChatSequence.current_message)
                .where(ChatSequence.id == sequence_id)
            ).one_or_none()
            if message_row is None:
                break

            message, parent_id = message_row
            messages_list.append(message)
            sequence_id = parent_id

        match_object.messages = messages_list[::-1]
        return match_object

    @router.get("/sequences/pinned")
    def get_pinned_sequences(
            limit: int = 20,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        pinned = history_db.execute(
            select(ChatSequence.id)
            .filter_by(user_pinned=True)
            .order_by(ChatSequence.generated_at.desc())
            .limit(limit)
        ).scalars()

        return {"sequence_ids": list(pinned)}

    app.include_router(router)
