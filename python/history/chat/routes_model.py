import json
import logging

from pydantic import BaseModel
from sqlalchemy import select

from history.chat.database import Message
from history.shared.database import get_db as get_history_db, ModelConfigRecord, InferenceJob
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


def fetch_model_info(ij_id) -> ModelConfigRecord | None:
    if ij_id is None:
        return None

    # NB Usually, running a query during iteration would need a second SQLAlchemy cursor-session-thing.
    history_db = next(get_history_db())
    return history_db.execute(
        select(ModelConfigRecord)
        .join(InferenceJob, InferenceJob.model_config == ModelConfigRecord.id)
        .where(InferenceJob.id == ij_id)
        .limit(1)
    ).scalar_one_or_none()


def translate_model_info(model0: ModelConfigRecord | None) -> Message:
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
        model0: ModelConfigRecord | None,
        model1: ModelConfigRecord,
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
