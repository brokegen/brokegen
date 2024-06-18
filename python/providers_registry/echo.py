from datetime import datetime, timezone
from typing import AsyncIterable, AsyncGenerator

from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID
from audit.http import AuditDB
from client.database import ChatMessage
from client.sequence_get import do_get_sequence
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecord, InferenceModelResponse, InferenceModelAddRequest, \
    lookup_inference_model_detailed, InferenceModelRecordOrm
from providers.orm import ProviderType, ProviderLabel, ProviderRecord
from providers.registry import BaseProvider, ProviderRegistry, ProviderFactory
from retrieval.faiss.retrieval import RetrievalLabel


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
            | AsyncIterable[InferenceModelRecord | InferenceModelResponse]):
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
            retrieval_label: RetrievalLabel,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ):  # -> AsyncIterable[JSONDict]:
        messages_list: list[ChatMessage] = \
            do_get_sequence(sequence_id, history_db, include_model_info_diffs=False)

        message = messages_list[-1]

        character: str
        for character in message.content:
            yield character


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
