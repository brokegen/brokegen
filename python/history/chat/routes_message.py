import logging
from datetime import datetime
from http.client import HTTPException
from typing import Optional

import fastapi.routing
from fastapi import FastAPI, Depends
from pydantic import BaseModel
from sqlalchemy import select

from _util.json import JSONDict
from history.chat.database import MessageID, Message
from inference.prompting.models import RoleName, PromptText
from providers.inference_models.database import HistoryDB, get_db as get_history_db

logger = logging.getLogger(__name__)


class MessageIn(BaseModel, frozen=True):
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

    app.include_router(router)
