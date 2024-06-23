import asyncio
import logging
from datetime import timezone, datetime

from sqlalchemy import select

from _util.status import ServerStatusHolder
from _util.typing import PromptText, FoundationModelRecordID
from client.chat_message import ChatMessage
from client.chat_sequence import ChatSequence
from client.database import HistoryDB
from providers.inference_models.orm import FoundationModelRecordOrm
from providers.orm import ProviderLabel
from providers.registry import ProviderRegistry

logger = logging.getLogger(__name__)


async def autoname_sequence(
        sequence: ChatSequence,
        preferred_autonaming_model: FoundationModelRecordID,
        status_holder: ServerStatusHolder,
        history_db: HistoryDB,
        registry: ProviderRegistry,
) -> PromptText | None:
    # Decide how to continue inference for this sequence
    autonaming_model: FoundationModelRecordOrm | None = history_db.execute(
        select(FoundationModelRecordOrm)
        .where(FoundationModelRecordOrm.id == preferred_autonaming_model)
    ).scalar_one_or_none()
    if autonaming_model is None:
        return None

    provider_label: ProviderLabel | None = registry.provider_label_from(autonaming_model)
    # Special case, for the custom implementation we already have.
    # TODO: Remove it once we have better abstractions, since this import breaks everything.
    if provider_label is not None and provider_label.type == "ollama":
        from client.sequence_get import fetch_messages_for_sequence
        import providers_registry

        messages_list: list[ChatMessage] = \
            fetch_messages_for_sequence(sequence.id, history_db, include_model_info_diffs=False)
        return await providers_registry.ollama.sequence_extend.autoname_sequence(
            messages_list,
            autonaming_model,
            status_holder,
        )

    await asyncio.sleep(10)
    return f"[mock autoname for ChatSequence#{sequence.id} -- {datetime.now(tz=timezone.utc)}]"
