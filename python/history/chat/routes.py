from http.client import HTTPException

import fastapi.routing
from fastapi import FastAPI, Depends
from pydantic import BaseModel
from sqlalchemy import select

from history.chat.database import MessageID, Message
from history.database import HistoryDB, get_db as get_history_db
from history.ollama.json import JSONDict
from prompting.models import RoleName, PromptText


class MessageIn(BaseModel):
    role: RoleName
    content: PromptText


class MessageOut(BaseModel):
    role: RoleName
    content: PromptText

    token_count: int | None
    generation_info: JSONDict | None


def install_routes(app: FastAPI):
    router = fastapi.routing.APIRouter()

    @router.post(
        "/messages",
        response_model=MessageID,
    )
    async def create_message(
            message: MessageIn,
            allow_duplicates: bool = False,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> MessageID:
        if not allow_duplicates:
            maybe_message_id = history_db.execute(
                select(Message.id)
                .filter_by(role=message.role, content=message.content)
                .limit(1)
            ).scalar_one_or_none()
            if maybe_message_id:
                return maybe_message_id

        new_object = Message(role=message.role, content=message.content)
        history_db.add(new_object)
        history_db.commit()

        return new_object.id

    @router.get(
        "/messages/{id:int}",
        response_model=MessageOut,
    )
    def get_chat(
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
            token_count=None,
            generation_info=None,
        )

    app.include_router(router)
