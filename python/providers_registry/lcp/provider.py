import logging
import os
from datetime import datetime, timezone
from typing import AsyncIterable, AsyncGenerator, AsyncIterator, Awaitable

import llama_cpp
import orjson
from sqlalchemy import select

from _util.json import JSONDict
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, PromptText, FoundationModelRecordID
from audit.http import AuditDB
from client.database import HistoryDB, get_db as get_history_db
from inference.continuation import InferenceOptions
from providers._util import local_provider_identifiers, local_fetch_machine_info
from providers.inference_models.orm import FoundationModelRecord, FoundationModelResponse, FoundationModelAddRequest, \
    lookup_foundation_model_detailed, FoundationModelRecordOrm
from providers.orm import ProviderRecord, ProviderRecordOrm
from providers.registry import BaseProvider

logger = logging.getLogger(__name__)


class LlamaCppProvider(BaseProvider):
    model_path: str
    underlying_model: llama_cpp.Llama | None = None

    def __init__(self, model_path: str):
        self.model_path = model_path

    async def _launch(
            self,
            verbose: bool = False,
    ):
        if self.underlying_model is not None:
            return

        logger.info(f"Loading llama_cpp model: {self.model_path}")
        self.underlying_model = llama_cpp.Llama(
            model_path=self.model_path,
            n_gpu_layers=-1,
            verbose=verbose,
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
        history_db: HistoryDB = next(get_history_db())

        provider_identifiers_dict = {
            "name": "lcp",
            # TODO: We should not be including per-file info; BaseProviders should support multiple models.
            # But, we need to rewrite this provider to do so.
            "endpoint": self.model_path,
            "version_info": llama_cpp.__version__,
        }

        provider_identifiers_dict.update(local_provider_identifiers())
        provider_identifiers = orjson.dumps(provider_identifiers_dict, option=orjson.OPT_SORT_KEYS)

        # Check for existing matches
        maybe_provider = history_db.execute(
            select(ProviderRecordOrm)
            .where(ProviderRecordOrm.identifiers == provider_identifiers)
        ).scalar_one_or_none()
        if maybe_provider is not None:
            return ProviderRecord.from_orm(maybe_provider)

        new_provider = ProviderRecordOrm(
            identifiers=provider_identifiers,
            created_at=datetime.now(tz=timezone.utc),
            machine_info=await local_fetch_machine_info(),
        )
        history_db.add(new_provider)
        history_db.commit()

        return ProviderRecord.from_orm(new_provider)

    async def list_models(self) -> (
            AsyncGenerator[FoundationModelRecord | FoundationModelResponse, None]
            | AsyncIterable[FoundationModelRecord | FoundationModelResponse]
    ):
        info_only: llama_cpp.Llama
        try:
            info_only = llama_cpp.Llama(
                model_path=self.model_path,
                verbose=False,
                vocab_only=True,
                logits_all=True,
            )
        except ValueError:
            # Set verbose=True + check its output to see where the errors are
            logger.warning(f"Failed to load file, ignoring: {self.model_path}")
            return

        inference_params = dict([
            (field, getattr(info_only.model_params, field))
            for field, _ in info_only.model_params._fields_
        ])
        for k, v in list(inference_params.items()):
            if isinstance(v, (bool, int)):
                inference_params[k] = v
            elif k in ("kv_overrides", "tensor_split"):
                inference_params[k] = getattr(info_only, k)
            elif k in ("progress_callback", "progress_callback_user_data"):
                del inference_params[k]
            else:
                inference_params[k] = str(v)

        model_name = os.path.basename(self.model_path)
        if model_name[-5:] == '.gguf':
            model_name = model_name[:-5]

        access_time = datetime.now(tz=timezone.utc)
        model_in = FoundationModelAddRequest(
            human_id=model_name,
            first_seen_at=access_time,
            last_seen=access_time,
            provider_identifiers=(await self.make_record()).identifiers,
            model_identifiers=info_only.metadata,
            combined_inference_parameters=inference_params,
        )

        history_db: HistoryDB = next(get_history_db())

        maybe_model: FoundationModelRecordID | None = lookup_foundation_model_detailed(model_in, history_db)
        if maybe_model is not None:
            maybe_model.merge_in_updates(model_in)
            history_db.add(maybe_model)
            history_db.commit()

            yield FoundationModelRecord.from_orm(maybe_model)

        else:
            logger.info(f"lcp constructed a new FoundationModelRecord: {model_in.model_dump_json()}")
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
