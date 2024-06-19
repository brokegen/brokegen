import asyncio
import functools
from datetime import datetime, timezone
from typing import AsyncIterable, AsyncGenerator, AsyncIterator, Awaitable

from _util.json import JSONDict, safe_get
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, PromptText
from audit.http import AuditDB
from client.database import ChatMessage
from client.sequence_get import do_get_sequence
from inference.continuation import InferenceOptions
from inference.logging import tee_to_console_output, consolidate_and_call, inference_event_logger, \
    construct_new_sequence_from
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecord, InferenceModelResponse, InferenceModelAddRequest, \
    lookup_inference_model_detailed, InferenceModelRecordOrm
from providers.orm import ProviderType, ProviderLabel, ProviderRecord
from providers.registry import BaseProvider, ProviderRegistry, ProviderFactory


async def _chat_bare(
        sequence_id: ChatSequenceID,
        history_db: HistoryDB,
        max_length: int = 120 * 4,
) -> AsyncIterator[str]:
    messages_list: list[ChatMessage] = do_get_sequence(sequence_id, history_db)
    message = messages_list[-1]

    character: str
    for character in message.content[:max_length]:
        yield character

    if len(message.content) > max_length:
        yield f"… [truncated, {len(message.content) - max_length} chars remaining]"


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
    def __init__(self, id: str):
        self.provider_id = id

    async def available(self) -> bool:
        return True

    async def make_record(self) -> ProviderRecord:
        return ProviderRecord(
            identifiers="echo",
        )

    async def list_models(self) -> (
            AsyncGenerator[InferenceModelRecord | InferenceModelResponse, None]
            | AsyncIterable[InferenceModelRecord | InferenceModelResponse]
    ):
        access_time = datetime.now(tz=timezone.utc)
        model_in = InferenceModelAddRequest(
            human_id=f"echo-{self.provider_id}",
            first_seen_at=access_time,
            last_seen=access_time,
            provider_identifiers=(await self.make_record()).identifiers,
            model_identifiers=None,
            combined_inference_parameters=None,
        )

        history_db: HistoryDB = next(get_history_db())

        maybe_model = lookup_inference_model_detailed(model_in, history_db)
        if maybe_model is not None:
            maybe_model.merge_in_updates(model_in)
            history_db.add(maybe_model)
            history_db.commit()

            yield InferenceModelRecord.from_orm(maybe_model)

        else:
            new_model = InferenceModelRecordOrm(**model_in.model_dump())
            history_db.add(new_model)
            history_db.commit()

            yield InferenceModelRecord.from_orm(new_model)

    async def chat(
            self,
            sequence_id: ChatSequenceID,
            inference_model: InferenceModelRecordOrm,
            inference_options: InferenceOptions,
            retrieval_context: Awaitable[PromptText | None],
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        iter0: AsyncIterator[str] = _chat_bare(sequence_id, history_db)
        iter1: AsyncIterator[str] = tee_to_console_output(iter0, lambda s: s)
        iter2: AsyncIterator[JSONDict] = _chat_slowed_down(iter1, status_holder)
        iter3: AsyncIterator[JSONDict] = consolidate_and_call(
            iter2, echo_consolidator, {},
            functools.partial(inference_event_logger, history_db=history_db),
            functools.partial(construct_new_sequence_from, history_db=history_db),
        )

        return iter3


class EchoProviderFactory(ProviderFactory):
    async def try_make(self, label: ProviderLabel) -> BaseProvider | None:
        if label.type == "echo":
            return EchoProvider(id=label.id)

        return None

    async def discover(
            self,
            provider_type: ProviderType | None,
            registry: ProviderRegistry,
    ) -> None:
        if provider_type is not None and provider_type != 'echo':
            return

        label = ProviderLabel(type="echo", id="epzhbwmjdtoexgstvtfkrnus")
        await registry.try_make(label)
