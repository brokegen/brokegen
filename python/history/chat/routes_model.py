import json
import logging

from pydantic import BaseModel

from history.chat.database import Message
from inference.prompting.models import RoleName, PromptText
from providers.inference_models.orm import InferenceModelRecordOrm

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
