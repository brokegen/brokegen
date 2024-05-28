import json
import logging
from http.client import HTTPException

import fastapi.routing
from fastapi import Depends
from pydantic import BaseModel
from sqlalchemy import Row
from sqlalchemy import select

from _util.typing import ChatSequenceID, RoleName, PromptText
from history.chat.database import ChatMessageOrm
from history.chat.database import ChatSequence
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm, lookup_inference_model

logger = logging.getLogger(__name__)


class InfoMessageOut(BaseModel):
    """
    This class is a bridge between "real" user/assistant messages,
    and ModelConfigRecord changes.

    TODO: Once we've written client support to render config changes,
          remove this and replace with a real config change.
    """
    role: RoleName = 'model info'
    content: PromptText


def translate_model_info(model0: InferenceModelRecordOrm | None) -> ChatMessageOrm:
    if model0 is None:
        return ChatMessageOrm(
            role='model config',
            content="no info available",
        )

    return ChatMessageOrm(
        role='model config',
        content=f"ModelConfigRecord: {json.dumps(model0.as_json(), indent=2)}"
    )


def translate_model_info_diff(
        model0: InferenceModelRecordOrm | None,
        model1: InferenceModelRecordOrm,
) -> InfoMessageOut | None:
    if model0 is None:
        return translate_model_info(model1)

    if model0 == model1:
        return None

    if model0.as_json() == model1.as_json():
        return None

    return ChatMessageOrm(
        role='model config',
        # TODO: pip install jsondiff would make this simpler, and also dumber
        content=f"ModelRecordConfigs changed:\n"
                f"{json.dumps(model0.as_json(), indent=2)}\n"
                f"{json.dumps(model1.as_json(), indent=2)}"
    )


def do_get_sequence(
        id: ChatSequenceID,
        history_db: HistoryDB,
        include_model_info_diffs: bool,
) -> list[ChatMessageOrm]:
    messages_list = []

    last_seen_model: InferenceModelRecordOrm | None = None
    sequence_id: ChatSequenceID = id
    while sequence_id is not None:
        logger.debug(f"Checking for sequence {id} => ancestor {sequence_id}")
        message_row: Row[ChatMessageOrm, ChatSequenceID | None, int] | None
        message_row = history_db.execute(
            select(ChatMessageOrm, ChatSequence.parent_sequence, ChatSequence.inference_job_id)
            .join(ChatMessageOrm, ChatMessageOrm.id == ChatSequence.current_message)
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


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.get("/sequences/{id:int}")
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
