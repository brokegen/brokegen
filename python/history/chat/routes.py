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


class MessageIn(BaseModel):
    role: RoleName
    content: PromptText
    created_at: Optional[datetime] = None


class MessageAddResponse(BaseModel):
    message_id: MessageID
    just_created: bool


class MessageOut(BaseModel):
    role: RoleName
    content: PromptText
    created_at: Optional[datetime] = None

    token_count: Optional[int] = None
    generation_info: Optional[JSONDict] = None


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

    @router.post(
        "/messages",
        response_model=MessageAddResponse,
    )
    async def create_message(
            message: MessageIn,
            allow_duplicates: bool = False,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> MessageAddResponse:
        if not allow_duplicates:
            maybe_message_id = history_db.execute(
                select(Message.id)
                .filter_by(role=message.role, content=message.content)
                .limit(1)
            ).scalar_one_or_none()
            if maybe_message_id:
                return MessageAddResponse(
                    message_id=maybe_message_id,
                    just_created=False,
                )

        new_object = Message(
            role=message.role,
            content=message.content,
            created_at=message.created_at,
        )
        history_db.add(new_object)
        history_db.commit()

        return MessageAddResponse(
            message_id=new_object.id,
            just_created=True,
        )

    @router.get(
        "/messages/{id:int}",
        response_model=MessageOut,
    )
    def get_message(
            id: MessageID,
            request_token_count: bool = True,
            request_generation_info: bool = True,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> MessageOut:
        match_object = history_db.execute(
            select(Message)
            .filter_by(id=id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(400, "No matching object")

        return MessageOut(
            role=match_object.role,
            content=match_object.content,
            created_at=match_object.created_at,
            token_count=None,
            generation_info=None,
        )

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

        return match_object

    app.include_router(router)
