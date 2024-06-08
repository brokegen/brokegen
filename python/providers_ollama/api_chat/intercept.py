import logging
from datetime import datetime, timezone

from sqlalchemy import select

from _util.json import safe_get, JSONArray, safe_get_arrayed
from _util.typing import PromptText
from history.chat.database import ChatSequence, ChatMessage, lookup_chat_message, ChatMessageOrm
from providers.inference_models.database import HistoryDB

logger = logging.getLogger(__name__)


def do_capture_chat_messages(
        chat_messages: JSONArray,
        history_db: HistoryDB,
) -> tuple[ChatSequence | None, PromptText | None]:
    prior_sequence: ChatSequence | None = None
    system_message: PromptText | None = None

    return prior_sequence, system_message
