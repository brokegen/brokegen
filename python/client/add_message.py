import logging
from http.client import HTTPException

import fastapi.routing
from fastapi import Depends
from pydantic import BaseModel
from sqlalchemy import select

from _util.typing import ChatMessageID
from client.database import ChatMessageOrm, ChatMessage, lookup_chat_message
from providers.inference_models.database import HistoryDB, get_db as get_history_db

logger = logging.getLogger(__name__)


class MessageAddResponse(BaseModel):
    message_id: ChatMessageID
    just_created: bool


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post(
        "/messages",
        response_model=MessageAddResponse,
    )
    async def create_message(
            response: fastapi.Response,
            message_in: ChatMessage,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> MessageAddResponse:
        maybe_model = lookup_chat_message(message_in, history_db)
        if maybe_model is not None:
            return MessageAddResponse(
                message_id=maybe_model.id,
                just_created=False,
            )

        new_object = ChatMessageOrm(**message_in.model_dump())
        history_db.add(new_object)
        history_db.commit()

        response.status_code = fastapi.status.HTTP_201_CREATED
        return MessageAddResponse(
            message_id=new_object.id,
            just_created=True,
        )

    @router_ish.get("/messages/{id:int}")
    def get_message(
            id: ChatMessageID,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        match_object = history_db.execute(
            select(ChatMessageOrm)
            .filter_by(id=id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(400, "No matching object")

        return match_object
