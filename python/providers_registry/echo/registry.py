import asyncio
import functools
from datetime import datetime, timezone
from typing import AsyncGenerator, AsyncIterator

from _util.json import JSONDict, safe_get
from _util.status import ServerStatusHolder
from _util.typing import PromptText, TemplatedPromptText
from audit.http import AuditDB
from client.message import ChatMessage
from client.database import HistoryDB, get_db as get_history_db
from inference.iterators import tee_to_console_output, consolidate_and_call
from inference.logging import construct_new_sequence_from
from providers.foundation_models.orm import FoundationModelRecord, FoundationModelAddRequest, \
    lookup_foundation_model_detailed, FoundationModelRecordOrm
from providers.orm import ProviderType, ProviderLabel, ProviderRecord, ProviderID
from providers.registry import BaseProvider, ProviderRegistry, ProviderFactory, InferenceOptions


async def _chat_bare(
        message_text: PromptText | TemplatedPromptText,
        max_length: int = 120 * 4,
) -> AsyncIterator[str]:
    character: str
    for character in message_text[:max_length]:
        yield character

    if len(message_text) > max_length:
        yield f"… [truncated, {len(message_text) - max_length} chars remaining]"


async def _chat_slowed_down(
        primordial_t: AsyncIterator[str],
        status_holder: ServerStatusHolder,
) -> AsyncIterator[JSONDict]:
    # DEBUG: Check that everyone is responsive during long waits
    await asyncio.sleep(3)

    async for item in primordial_t:
        # NB Without sleeps, packets seem to get eaten somewhere.
        # Probably client-side, but TBD.
        await asyncio.sleep(0.05)
        yield {
            "message": {
                "role": "assistant",
                "content": item,
            },
            "status": status_holder.get(),
            "done": False,
        }

    await asyncio.sleep(1.0)
    yield {
        "status": status_holder.get(),
        "done": True,
        # "new_sequence_id": -5,
    }


def echo_consolidator(chunk: JSONDict, consolidated_response: JSONDict) -> JSONDict:
    if not consolidated_response:
        return chunk

    message: str = safe_get(chunk, "message", "content")
    consolidated_response["message"]["content"] = message

    return consolidated_response


class EchoProvider(BaseProvider):
    def __init__(self, provider_id: ProviderID):
        self.provider_id = provider_id

    async def available(self) -> bool:
        return True

    async def make_record(self) -> ProviderRecord:
        return ProviderRecord(
            identifiers="echo",
        )

    async def list_models_nocache(
            self,
    ) -> AsyncGenerator[FoundationModelRecord, None]:
        access_time = datetime.now(tz=timezone.utc)
        model_in = FoundationModelAddRequest(
            human_id=f"echo-model",
            first_seen_at=access_time,
            last_seen=access_time,
            provider_identifiers=(await self.make_record()).identifiers,
            model_identifiers=None,
            combined_inference_parameters=None,
        )

        history_db: HistoryDB = next(get_history_db())

        maybe_model = lookup_foundation_model_detailed(model_in, history_db)
        if maybe_model is not None:
            maybe_model.merge_in_updates(model_in)
            history_db.add(maybe_model)
            history_db.commit()

            yield FoundationModelRecord.model_validate(maybe_model)

        else:
            new_model = FoundationModelRecordOrm(**model_in.model_dump())
            history_db.add(new_model)
            history_db.commit()

            yield FoundationModelRecord.model_validate(new_model)

    async def do_chat_nolog(
            self,
            messages_list: list[ChatMessage],
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        message_text: PromptText = messages_list[-1].content

        iter0: AsyncIterator[str] = _chat_bare(message_text)
        iter1: AsyncIterator[str] = tee_to_console_output(iter0, lambda s: s)
        iter2: AsyncIterator[JSONDict] = _chat_slowed_down(iter1, status_holder)
        iter3: AsyncIterator[JSONDict] = consolidate_and_call(
            iter2, echo_consolidator, {},
            functools.partial(construct_new_sequence_from, history_db=history_db),
        )

        return iter3

    def generate(
            self,
            prompt: TemplatedPromptText,
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncGenerator[JSONDict, None]:
        iter0: AsyncIterator[str] = _chat_bare(prompt)
        iter1: AsyncIterator[str] = tee_to_console_output(iter0, lambda s: s)
        iter2: AsyncIterator[JSONDict] = _chat_slowed_down(iter1, status_holder)
        iter3: AsyncIterator[JSONDict] = consolidate_and_call(
            iter2, echo_consolidator, {},
            functools.partial(construct_new_sequence_from, history_db=history_db),
        )

        return iter3


class EchoProviderFactory(ProviderFactory):
    async def try_make(self, label: ProviderLabel) -> BaseProvider | None:
        if label.type == "echo":
            return EchoProvider(provider_id=label.id)

        return None

    async def discover(
            self,
            provider_type: ProviderType | None,
            registry: ProviderRegistry,
    ) -> None:
        if provider_type is not None and provider_type != 'echo':
            return

        label = ProviderLabel(type="echo", id="[singleton]")
        await registry.try_make(label)
