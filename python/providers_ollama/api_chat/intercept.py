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

    for index in range(len(chat_messages)):
        message_copy = dict(chat_messages[index])
        if safe_get(message_copy, "role") == "system":
            if system_message is not None:
                logger.warning(f'Received several "system" messages, overwriting previous {system_message=}')
            system_message = safe_get(message_copy, "content") or system_message
        elif safe_get(message_copy, "role") not in ("user", "assistant"):
            logger.warning(f"Received unknown Ollama role, continuing anyway: {safe_get(message_copy, 'role')}")

        if safe_get_arrayed(chat_messages, index, 'images'):
            logger.error("Client submitted images for upload, ignoring")
        if 'images' in message_copy:
            del message_copy['images']
        if 'created_at' not in message_copy:
            # set to None for the purposes of search + model_dump, since 'del' wouldn't work
            message_copy['created_at'] = None

        message_in = ChatMessage(**message_copy)
        message_in_orm = lookup_chat_message(message_in, history_db)
        if message_in_orm is None:
            message_in_orm = ChatMessageOrm(**message_in.model_dump())
            message_in_orm.created_at = (
                    safe_get_arrayed(chat_messages, index, 'created_at')
                    or message_in_orm.created_at
                    or datetime.now(tz=timezone.utc)
            )
            history_db.add(message_in_orm)
            history_db.commit()

        # And then check for Sequences that might already exist, because we want to surface the new chat in every app
        sequence_in: ChatSequence | None = history_db.execute(
            select(ChatSequence)
            .where(ChatSequence.current_message == message_in_orm.id)
            .order_by(ChatSequence.generated_at.desc())
            .limit(1)
        ).scalar_one_or_none()
        if sequence_in is not None:
            # This check will _only_ match against prior sequences if the histories match exactly.
            # In particular, the root message and root sequence must not be parented!!
            if sequence_in.parent_sequence == prior_sequence:
                prior_sequence = sequence_in
                continue

        logger.info(f"Constructing new ChatSequence from ChatMessage#{message_in_orm.id}"
                    f" because {sequence_in=} and {prior_sequence=}")

        sequence_in = ChatSequence(
            user_pinned=index == len(chat_messages) - 1,
            current_message=message_in_orm.id,
            generated_at=datetime.now(tz=timezone.utc),
            generation_complete=True,
        )
        if prior_sequence is not None:
            sequence_in.human_desc = prior_sequence.human_desc
            sequence_in.parent_sequence = prior_sequence.id
            sequence_in.inference_error = "[unknown, skimmed from /api/chat]"

        history_db.add(sequence_in)
        history_db.commit()

        prior_sequence = sequence_in
        continue

    return prior_sequence, system_message