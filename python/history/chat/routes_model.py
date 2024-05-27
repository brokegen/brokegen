import json
import logging

from pydantic import BaseModel
from sqlalchemy import select

from history.chat.database import Message
from providers.inference_models.database import get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm, InferenceEventOrm
from inference.prompting.models import RoleName, PromptText

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


def fetch_model_info(ij_id) -> InferenceModelRecordOrm | None:
    if ij_id is None:
        return None

    # NB Usually, running a query during iteration would need a second SQLAlchemy cursor-session-thing.
    history_db = next(get_history_db())
    return history_db.execute(
        select(InferenceConfigRecordOrm)
        .join(InferenceEventOrm, InferenceEventOrm.model_record_id == InferenceConfigRecordOrm.id)
        .where(InferenceEventOrm.id == ij_id)
        .limit(1)
    ).scalar_one_or_none()


def translate_model_info(model0: InferenceModelRecordOrm | None) -> Message:
    if model0 is None:
        return Message(
            role='model config',
            content="no info available",
        )

    return Message(
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

    return Message(
        role='model config',
        # TODO: pip install jsondiff would make this simpler, and also dumber
        content=f"ModelRecordConfigs changed:\n"
                f"{json.dumps(model0.as_json(), indent=2)}\n"
                f"{json.dumps(model1.as_json(), indent=2)}"
    )
