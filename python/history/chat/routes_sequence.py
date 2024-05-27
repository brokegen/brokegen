import logging
from datetime import datetime
from http.client import HTTPException
from typing import Optional

import fastapi.routing
import orjson
from fastapi import Depends
from pydantic import BaseModel, Json
from sqlalchemy import select, Row

from history.chat.database import Message, ChatSequence
from _util.typing import MessageID, ChatSequenceID
from history.chat.routes_model import translate_model_info_diff, translate_model_info
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceEventOrm, lookup_inference_model, InferenceModelRecordOrm, \
    InferenceReason
from providers.inference_models.orm import InferenceModelRecordID, InferenceEventID

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


class InferenceEventIn(BaseModel):
    prompt_tokens: Optional[int] = None
    prompt_eval_time: Optional[float] = None
    prompt_with_templating: Optional[str] = None

    response_created_at: Optional[datetime] = None
    response_tokens: Optional[int] = None
    response_eval_time: Optional[float] = None

    response_error: Optional[str] = None
    response_info: Optional[Json] = None
    response_info_str: Optional[str] = None
    """
    Included for legacy reasons, aka can't figure out how to get client to encode the JSON correctly.
    """

    parent_sequence: Optional[ChatSequenceID] = None
    reason: Optional[InferenceReason] = None


class InferenceJobAddResponse(BaseModel):
    ijob_id: InferenceEventID
    just_created: bool


def do_get_sequence(
        id: ChatSequenceID,
        history_db: HistoryDB,
        include_model_info_diffs: bool,
) -> list[Message]:
    messages_list = []

    last_seen_model: InferenceModelRecordOrm | None = None
    sequence_id: ChatSequenceID = id
    while sequence_id is not None:
        logger.debug(f"Checking for sequence {id} => ancestor {sequence_id}")
        message_row: Row[Message, ChatSequenceID | None, int] | None
        message_row = history_db.execute(
            select(Message, ChatSequence.parent_sequence, ChatSequence.inference_job_id)
            .join(Message, Message.id == ChatSequence.current_message)
            .where(ChatSequence.id == sequence_id)
        ).one_or_none()
        if message_row is None:
            break

        message, parent_id, _ = message_row
        messages_list.append(message)
        sequence_id = parent_id

        # For "debug" purposes, compute the diffs even if we don't render them
        if message_row[2] is not None:
            this_model = lookup_inference_model(message_row[2], history_db)
            if last_seen_model is not None:
                # Since we're iterating in child-to-parent order, dump diffs backwards if something changed.
                mdiff = translate_model_info_diff(last_seen_model, this_model)
                if mdiff is not None:
                    if include_model_info_diffs:
                        messages_list.append(mdiff)

            last_seen_model = this_model

    # End of iteration, populate "initial" model info, if needed
    if include_model_info_diffs:
        messages_list.append(translate_model_info(last_seen_model))

    return messages_list[::-1]


def construct_router():
    router = fastapi.routing.APIRouter()

    @router.post("/sequences")
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

    @router.post("/models/{model_record_id:int}/inference-events")
    def construct_inference_event(
            response: fastapi.Response,
            model_record_id: InferenceModelRecordID,
            inference_event_in: InferenceEventIn,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> InferenceJobAddResponse:
        # Check for matches
        filtered_inference_event_in = {
            "model_record_id": model_record_id,
        }
        for k, v in inference_event_in.model_dump().items():
            # SQL NULL always compares not equal, so skip those items
            if v:
                filtered_inference_event_in[k] = v

        if "response_info_str" in filtered_inference_event_in:
            if not filtered_inference_event_in.get("response_info", None):
                # Enforce response_info sort order
                sorted_response_info = orjson.loads(
                    orjson.dumps(
                        orjson.loads(filtered_inference_event_in["response_info_str"]),
                        option=orjson.OPT_SORT_KEYS
                    )
                )
                filtered_inference_event_in["response_info"] = sorted_response_info
                del filtered_inference_event_in["response_info_str"]

        match_object = history_db.execute(
            select(InferenceEventOrm.id)
            .filter_by(**filtered_inference_event_in)
        ).scalar_one_or_none()
        if match_object is not None:
            return InferenceJobAddResponse(
                ijob_id=match_object,
                just_created=False,
            )

        new_object = InferenceEventOrm(**filtered_inference_event_in)
        history_db.add(new_object)
        history_db.commit()

        response.status_code = fastapi.status.HTTP_201_CREATED
        return InferenceJobAddResponse(
            ijob_id=new_object.id,
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

        # This modifies the SQLAlchemy object, when we should really have turned it into a JSON first.
        # TODO: Turn the `match_object` into a JSON object first.
        match_object.messages = do_get_sequence(id, history_db, include_model_info_diffs=True)
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

    return router
