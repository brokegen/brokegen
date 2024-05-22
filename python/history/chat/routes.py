from datetime import datetime
from http.client import HTTPException

import fastapi.routing
import starlette
from fastapi import FastAPI, Depends
from pydantic import BaseModel
from sqlalchemy import select
from starlette.requests import Request

from history.chat.database import MessageID, Message
from history.ollama.json import JSONDict
from history.shared.database import HistoryDB, get_db as get_history_db
from inference.prompting.models import RoleName, PromptText


class MessageIn(BaseModel):
    role: RoleName
    content: PromptText
    created_at: datetime | None


class MessageAddResponse(BaseModel):
    message_id: MessageID
    just_created: bool


class MessageOut(BaseModel):
    role: RoleName
    content: PromptText
    created_at: datetime | None

    token_count: int | None
    generation_info: JSONDict | None


def install_routes(app: FastAPI):
    router = fastapi.routing.APIRouter()

    @router.post(
        "/messages",
        response_model=MessageAddResponse,
    )
    async def create_message(
            request: starlette.requests.Request,
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

    app.include_router(router)
