import logging
from datetime import datetime, timedelta, timezone
from typing import Optional, Annotated

import fastapi.routing
import fastapi.routing
from fastapi import Depends, Query
from pydantic import BaseModel
from sqlalchemy import select

from _util.typing import ChatMessageID
from _util.typing import ChatSequenceID
from client.database import ChatSequence
from providers.inference_models.database import HistoryDB, get_db as get_history_db

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


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post("/sequences")
    async def post_sequence(
            response: fastapi.Response,
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

        new_object = ChatSequence(**seq_in.model_dump())
        history_db.add(new_object)
        history_db.commit()

        response.status_code = fastapi.status.HTTP_201_CREATED
        return SequenceAddResponse(
            sequence_id=new_object.id,
            just_created=True,
        )

    @router_ish.get("/sequences/pinned")
    def get_pinned_recent_sequences(
            lookback: Annotated[float | None, Query(description="Maximum age in seconds for returned items")] = None,
            limit: Annotated[int | None, Query(description="Maximum number of items to return")] = None,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        query = (
            select(ChatSequence.id)
            .filter_by(user_pinned=True)
            .order_by(ChatSequence.generated_at.desc())
        )
        if lookback is not None:
            reference_time = datetime.now(tz=timezone.utc) - timedelta(seconds=lookback)
            query = query.where(ChatSequence.generated_at > reference_time)
        if query is not None:
            query = query.limit(limit)

        pinned = history_db.execute(query).scalars()
        return {"sequence_ids": list(pinned)}
