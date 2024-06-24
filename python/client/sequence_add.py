import logging
from datetime import datetime, timezone
from typing import Optional

import fastapi.routing
import fastapi.routing
from fastapi import Depends
from pydantic import BaseModel
from sqlalchemy import select

from _util.typing import ChatMessageID
from _util.typing import ChatSequenceID
from .chat_sequence import ChatSequenceOrm
from .database import HistoryDB, get_db as get_history_db

logger = logging.getLogger(__name__)


class SequenceIn(BaseModel):
    human_desc: Optional[str] = None
    user_pinned: Optional[bool] = None

    current_message: ChatMessageID
    parent_sequence: Optional[ChatSequenceID] = None

    generated_at: Optional[datetime] = None
    generation_complete: bool
    inference_job_id: Optional[int] = None
    inference_error: Optional[str] = None


class SequenceAddResponse(BaseModel):
    sequence_id: ChatSequenceID
    just_created: bool


def do_extend_sequence(
        sequence_id: ChatSequenceID,
        message_id: ChatMessageID,
        history_db: HistoryDB,
) -> ChatSequenceOrm:
    """
    This just stacks a new user message onto the end of our chain.

    Rely on /continue to run any inference.
    """
    # First, store the message that was painstakingly generated for us.
    original_sequence = history_db.execute(
        select(ChatSequenceOrm)
        .filter_by(id=sequence_id)
    ).scalar_one()

    user_sequence = ChatSequenceOrm(
        human_desc=original_sequence.human_desc,
        parent_sequence=original_sequence.id,
        generated_at=datetime.now(tz=timezone.utc),
        generation_complete=False,
    )

    user_sequence.current_message = message_id
    user_sequence.generation_complete = True

    # Mark this user response as the current up-to-date
    user_sequence.user_pinned = original_sequence.user_pinned
    original_sequence.user_pinned = False

    history_db.add(original_sequence)
    history_db.add(user_sequence)
    history_db.commit()

    return user_sequence


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post("/sequences")
    async def post_sequence(
            response: fastapi.Response,
            seq_in: SequenceIn,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> SequenceAddResponse:
        maybe_sequence_id = history_db.execute(
            select(ChatSequenceOrm.id)
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

        new_object = ChatSequenceOrm(**seq_in.model_dump())
        history_db.add(new_object)
        history_db.commit()

        response.status_code = fastapi.status.HTTP_201_CREATED
        return SequenceAddResponse(
            sequence_id=new_object.id,
            just_created=True,
        )

    @router_ish.post("/sequences/{sequence_id:int}/add/{message_id:int}")
    def extend_sequence(
            sequence_id: ChatSequenceID,
            message_id: ChatMessageID,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        return {
            "sequence_id": do_extend_sequence(sequence_id, message_id, history_db).id,
        }
