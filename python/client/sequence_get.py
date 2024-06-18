import json
import logging
from datetime import datetime, timezone
from http.client import HTTPException

import fastapi.routing
from fastapi import Depends
from pydantic import BaseModel
from sqlalchemy import select

from _util.typing import ChatSequenceID, RoleName, PromptText, ChatMessageID
from client.database import ChatMessageOrm, lookup_sequence_parents, ChatMessage, lookup_chat_message
from client.database import ChatSequence
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm, lookup_inference_model_for_event_id

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


def translate_model_info(model0: InferenceModelRecordOrm | None) -> InfoMessageOut:
    if model0 is None:
        return InfoMessageOut(
            role='model config',
            content="no info available",
        )

    return InfoMessageOut(
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

    return InfoMessageOut(
        role='model config',
        # TODO: pip install jsondiff would make this simpler, and also dumber
        content=f"ModelRecordConfigs changed:\n"
                f"{json.dumps(model0.as_json(), indent=2)}\n"
                f"{json.dumps(model1.as_json(), indent=2)}"
    )


def do_get_sequence(
        id: ChatSequenceID,
        history_db: HistoryDB,
        include_model_info_diffs: bool = False,
) -> list[ChatMessage | InfoMessageOut]:
    messages_list: list[ChatMessage | InfoMessageOut] = []
    last_seen_model: InferenceModelRecordOrm | None = None

    sequence: ChatSequence
    for sequence in lookup_sequence_parents(id, history_db):
        message = history_db.execute(
            select(ChatMessageOrm)
            .where(ChatMessageOrm.id == sequence.current_message)
        ).scalar_one_or_none()
        if message is not None:
            message_out = ChatMessage.from_orm(message)
            messages_list.append(message_out)

        # For "debug" purposes, compute the diffs even if we don't render them
        if sequence.inference_job_id is not None:
            this_model = lookup_inference_model_for_event_id(sequence.inference_job_id, history_db)
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


def do_extend_sequence(
        sequence_id: ChatSequenceID,
        message_id: ChatMessageID,
        history_db: HistoryDB,
) -> ChatSequence:
    """
    This just stacks a new user message onto the end of our chain.

    Rely on /continue to run any inference.
    """
    # First, store the message that was painstakingly generated for us.
    original_sequence = history_db.execute(
        select(ChatSequence)
        .filter_by(id=sequence_id)
    ).scalar_one()

    user_sequence = ChatSequence(
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
    @router_ish.get("/sequences/{sequence_id:int}")
    def get_sequence(
            sequence_id: ChatSequenceID,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        match_object = history_db.execute(
            select(ChatSequence)
            .filter_by(id=sequence_id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(400, "No matching object")

        # This modifies the SQLAlchemy object, when we should really have turned it into a JSON first.
        # TODO: Turn the `match_object` into a JSON object first.
        match_object.messages = do_get_sequence(sequence_id, history_db, include_model_info_diffs=True)

        # Stick latest model name onto SequenceID, for client ease-of-display
        for sequence in lookup_sequence_parents(sequence_id, history_db):
            model = lookup_inference_model_for_event_id(sequence.inference_job_id, history_db)
            if model is not None:
                match_object.inference_model_id = model.id
                break

        return match_object

    @router_ish.post("/sequences/{sequence_id:int}/add/{message_id:int}")
    def extend_sequence(
            sequence_id: ChatSequenceID,
            message_id: ChatMessageID,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        return {
            "sequence_id": do_extend_sequence(sequence_id, message_id, history_db).id,
        }
