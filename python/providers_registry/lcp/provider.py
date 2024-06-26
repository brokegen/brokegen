from datetime import datetime, timezone
from typing import AsyncIterable, AsyncGenerator, AsyncIterator, Awaitable

import llama_cpp

from _util.json import JSONDict
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, PromptText
from audit.http import AuditDB
from client.database import HistoryDB, get_db as get_history_db
from inference.continuation import InferenceOptions
from providers.inference_models.orm import FoundationModelRecord, FoundationModelResponse, FoundationModelAddRequest, \
    lookup_foundation_model_detailed, FoundationModelRecordOrm
from providers.orm import ProviderRecord
from providers.registry import BaseProvider


class LlamaCppProvider(BaseProvider):
    model_path: str
    underlying_model: llama_cpp.Llama | None = None

    def __init__(self, model_path: str):
        self.model_path = model_path

    def _launch(self):
        if self.underlying_model is not None:
            return

        self.underlying_model = llama_cpp.Llama(
            model_path=self.model_path,
            verbose=True,
        )

    async def available(self) -> bool:
        # Do a quick tokenize/detokenize test run
        sample_text_str = "✎👍 ｃｏｍｐｌｅｘ UTF-8 𝓉𝑒𝓍𝓉, but mostly em🍪jis  🎀  🐔 ⋆ 🐞"
        sample_text: bytes = sample_text_str.encode('utf-8')

        just_tokens: llama_cpp.Llama = llama_cpp.Llama(
            model_path=self.model_path,
            verbose=False,
            vocab_only=True,
            logits_all=True,
        )

        tokenized: list[int] = just_tokens.tokenize(sample_text)
        detokenized: bytes = just_tokens.detokenize(tokenized)

        return sample_text == detokenized

    async def make_record(self) -> ProviderRecord:
        return ProviderRecord(
            identifiers="lcp",
        )

    async def list_models(self) -> (
            AsyncGenerator[FoundationModelRecord | FoundationModelResponse, None]
            | AsyncIterable[FoundationModelRecord | FoundationModelResponse]
    ):
        access_time = datetime.now(tz=timezone.utc)
        model_in = FoundationModelAddRequest(
            human_id=f"lcp-{self.model_path}",
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

            yield FoundationModelRecord.from_orm(maybe_model)

        else:
            new_model = FoundationModelRecordOrm(**model_in.model_dump())
            history_db.add(new_model)
            history_db.commit()

            yield FoundationModelRecord.from_orm(new_model)

    def chat(
            self,
            sequence_id: ChatSequenceID,
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            retrieval_context: Awaitable[PromptText | None],
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        for _ in []:
            yield {}
