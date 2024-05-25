import logging
from datetime import datetime
from http.client import HTTPException
from typing import Optional, Any

import fastapi.routing
import orjson
from fastapi import FastAPI, Depends
from pydantic import BaseModel, Json
from sqlalchemy import select, Row
from typing_extensions import deprecated

from history.chat.database import MessageID, Message, ChatSequenceID, ChatSequence
from history.chat.routes_model import fetch_model_info, translate_model_info_diff, translate_model_info
from history.shared.database import HistoryDB, get_db as get_history_db, ModelConfigRecord, ModelConfigID, \
    InferenceJobID, InferenceJob

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


class InferenceJobIn(BaseModel):
    model_config_id: ModelConfigID

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


class InferenceJobAddResponse(BaseModel):
    ijob_id: InferenceJobID
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

    @router.post("/sequences/none/inference-job")
    def construct_inference_job(
            ijob_in: InferenceJobIn,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> InferenceJobAddResponse:
        """
        TODO: Confirm that this function is idempotent-enough for chat imports.
        """
        match_object = history_db.execute(
            select(InferenceJob.id)
            .filter_by(
                model_config=ijob_in.model_config_id,
                # TODO: Check whether these do the right thing in NULL cases
                prompt_with_templating=ijob_in.prompt_with_templating,
                response_created_at=ijob_in.response_created_at,
            )
            .limit(1)
        ).scalar_one_or_none()
        if match_object is not None:
            return InferenceJobAddResponse(
                ijob_id=match_object,
                just_created=False,
            )

        new_object = InferenceJob(
            model_config=ijob_in.model_config_id,
            prompt_tokens=ijob_in.prompt_tokens,
            prompt_eval_time=ijob_in.prompt_eval_time,
            prompt_with_templating=ijob_in.prompt_with_templating,
            response_created_at=ijob_in.response_created_at,
            response_tokens=ijob_in.response_tokens,
            response_eval_time=ijob_in.response_eval_time,
            response_error=ijob_in.response_error,
            response_info=ijob_in.response_info or orjson.loads(ijob_in.response_info_str),
        )
        history_db.add(new_object)
        history_db.commit()

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

        messages_list = []

        last_seen_model: ModelConfigRecord | None = None
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

            if message_row[2] is not None:
                this_model = fetch_model_info(message_row[2])
                if last_seen_model is not None:
                    # Since we're iterating in child-to-parent order, dump diffs backwards if something changed.
                    messages_list.append(translate_model_info_diff(last_seen_model, this_model))

                last_seen_model = this_model

        # End of iteration, populate "initial" model info, if needed
        messages_list.append(translate_model_info(last_seen_model))

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
