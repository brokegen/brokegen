import logging

from _util.status import ServerStatusHolder
from _util.typing import PromptText, FoundationModelRecordID
from client.chat_sequence import ChatSequence

logger = logging.getLogger(__name__)


async def autoname_sequence(
        sequence: ChatSequence,
        preferred_autonaming_model: FoundationModelRecordID,
        status_holder: ServerStatusHolder,
) -> PromptText | None:
    return f"[mock autoname for ChatSequence#{sequence.id}]"
