import asyncio
import functools
from datetime import datetime, timezone
from typing import AsyncGenerator, AsyncIterator

import sqlalchemy
from _util.json import JSONDict, safe_get
from _util.status import ServerStatusHolder
from _util.typing import PromptText, TemplatedPromptText, ChatSequenceID
from audit.http import AuditDB
from client.message import ChatMessage, ChatMessageOrm
from client.database import HistoryDB, get_db as get_history_db
from client.sequence import ChatSequenceOrm
from client.sequence_get import fetch_messages_for_sequence
from inference.iterators import tee_to_console_output, consolidate_and_call, consolidate_and_yield
from inference.logging import construct_new_sequence_from
from providers.foundation_models.orm import FoundationModelRecord, FoundationModelAddRequest, \
    lookup_foundation_model_detailed, FoundationModelRecordOrm
from providers.orm import ProviderType, ProviderLabel, ProviderRecord, ProviderID
from providers.registry import BaseProvider, ProviderRegistry, ProviderFactory, InferenceOptions
from sqlalchemy import select


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


def echo_consolidator(chunk: JSONDict, consolidated_response: JSONDict) -> JSONDict:
    if not consolidated_response:
        return chunk

    message: str = safe_get(chunk, "message", "content")
    consolidated_response["message"]["content"] += message or ""

    return consolidated_response


class EchoProvider(BaseProvider):
    def __init__(self, provider_id: ProviderID):
        super().__init__()
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

    async def do_chat(
            self,
            sequence_id: ChatSequenceID,
            messages_list: list[ChatMessage],
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        original_sequence = history_db.execute(
            select(ChatSequenceOrm)
            .where(ChatSequenceOrm.id == sequence_id)
        ).scalar_one()

        async def record_new_sequence(
                consolidated_response: JSONDict,
        ) -> AsyncIterator[JSONDict]:
            yield {
                "status": "Committing new response from \"echo\" provider",
                "done": False,
            }

            try:
                new_echo_message = ChatMessageOrm(
                    role="assistant",
                    content=safe_get(consolidated_response, "message", "content"),
                    created_at=datetime.now(tz=timezone.utc),
                )
                history_db.add(new_echo_message)
                history_db.flush()

                # Add what we need for response_sequence
                response_sequence = ChatSequenceOrm(
                    human_desc=original_sequence.human_desc,
                    user_pinned=False,
                    current_message=new_echo_message.id,
                    parent_sequence=original_sequence.id,
                )

                history_db.add(response_sequence)

                response_sequence.generated_at = new_echo_message.created_at
                response_sequence.generation_complete = True
                response_sequence.inference_job_id = None

                history_db.commit()

                await asyncio.sleep(1.0)
                yield {
                    "status": status_holder.get(),
                    "done": True,
                    "new_message_id": new_echo_message.id,
                    "new_sequence_id": response_sequence.id,
                }

            except sqlalchemy.exc.SQLAlchemyError:
                history_db.rollback()
                status_holder.set(f"Failed to create add-on ChatSequence from {consolidated_response}")
                yield {
                    "error": "Failed to create add-on ChatSequence",
                    "done": True,
                }

            except Exception:
                status_holder.set(f"Failed to create add-on ChatSequence from {consolidated_response}")
                yield {
                    "error": "Failed to create add-on ChatSequence",
                    "done": True,
                }

        messages_list: list[ChatMessage] = fetch_messages_for_sequence(sequence_id, history_db)
        message_text: PromptText = messages_list[-1].content

        iter0: AsyncIterator[str] = _chat_bare(message_text)
        iter1: AsyncIterator[str] = tee_to_console_output(iter0, lambda s: s)
        iter2: AsyncIterator[JSONDict] = _chat_slowed_down(iter1, status_holder)
        iter3: AsyncIterator[JSONDict] = consolidate_and_yield(
            iter2, echo_consolidator, {},
            record_new_sequence,
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

        return iter2


class EchoProviderFactory(ProviderFactory):
    async def try_make_nocache(self, label: ProviderLabel) -> BaseProvider | None:
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
