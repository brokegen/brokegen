import logging
import os
from datetime import datetime, timezone
from typing import AsyncGenerator, AsyncIterator, Iterator

import llama_cpp
import orjson
import sqlalchemy
from sqlalchemy import select

from _util.json import JSONDict, safe_get, safe_get_arrayed
from _util.status import ServerStatusHolder
from _util.typing import FoundationModelRecordID
from audit.http import AuditDB
from client.database import HistoryDB, get_db as get_history_db
from client.message import ChatMessage
from inference.iterators import to_async, consolidate_and_call
from providers.foundation_models.orm import FoundationModelRecord, FoundationModelAddRequest, \
    lookup_foundation_model_detailed, FoundationModelRecordOrm, InferenceEventOrm
from providers.orm import ProviderRecord, ProviderRecordOrm
from providers.registry import BaseProvider, InferenceOptions
from providers_registry._util import local_provider_identifiers, local_fetch_machine_info

logger = logging.getLogger(__name__)


class _OneModel:
    model_path: str
    underlying_model: llama_cpp.Llama | None = None

    def __init__(self, model_path: str):
        self.model_path = model_path

    async def launch(
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
            # TODO: Figure out a more elegant way to decide the max.
            n_ctx=32_768,
        )

        # DEBUG: Check the contents of this, decide whether to put it in storage
        print(llama_cpp.llama_print_system_info().decode("utf-8"))

    async def available(self) -> bool:
        # Do a quick tokenize/detokenize test run
        sample_text_str = "✎👍 ｃｏｍｐｌｅｘ UTF-8 𝓉𝑒𝓍𝓉, but mostly em🍪jis  🎀  🐔 ⋆ 🐞"
        sample_text: bytes = sample_text_str.encode('utf-8')

        try:
            just_tokens: llama_cpp.Llama = llama_cpp.Llama(
                model_path=self.model_path,
                verbose=False,
                vocab_only=True,
                logits_all=True,
            )
        except ValueError as e:
            logger.error(f"LlamaCppProvider.available: Failed to load file, ignoring: {self.model_path}")
            logger.debug(e)
            return False

        tokenized: list[int] = just_tokens.tokenize(sample_text)
        detokenized: bytes = just_tokens.detokenize(tokenized)

        return sample_text == detokenized

    async def as_info(
            self,
            provider_record: ProviderRecord,
            path_prefix: str,
    ) -> FoundationModelRecord | None:
        info_only: llama_cpp.Llama
        try:
            info_only = llama_cpp.Llama(
                model_path=self.model_path,
                verbose=False,
                vocab_only=True,
                logits_all=True,
            )
        except ValueError as e:
            logger.error(f"LlamaCppProvider.as_info: Failed to load file, ignoring: {self.model_path}")
            logger.debug(e)
            return None

        model_name = os.path.basename(self.model_path)
        if model_name[-5:] == '.gguf':
            model_name = model_name[:-5]

        model_identifiers = info_only.metadata
        # TODO: This shouldn't be part of the unique identifiers, but then, what would?
        model_identifiers["path"] = os.path.relpath(self.model_path, path_prefix)
        model_identifiers = orjson.loads(
            # Keep these sorted in alphabetical order, for consistency
            orjson.dumps(model_identifiers, option=orjson.OPT_SORT_KEYS)
        )

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

        inference_params = orjson.loads(
            # Keep these sorted in alphabetical order, for consistency
            orjson.dumps(inference_params, option=orjson.OPT_SORT_KEYS)
        )

        access_time = datetime.now(tz=timezone.utc)
        model_in = FoundationModelAddRequest(
            human_id=model_name,
            first_seen_at=access_time,
            last_seen=access_time,
            provider_identifiers=provider_record.identifiers,
            model_identifiers=model_identifiers,
            combined_inference_parameters=inference_params,
        )

        history_db: HistoryDB = next(get_history_db())

        maybe_model: FoundationModelRecordID | None = lookup_foundation_model_detailed(model_in, history_db)
        if maybe_model is not None:
            maybe_model.merge_in_updates(model_in)
            history_db.add(maybe_model)
            history_db.commit()

            return FoundationModelRecord.model_validate(maybe_model)

        else:
            logger.info(f"lcp constructed a new FoundationModelRecord: {model_in.model_dump_json()}")
            new_model = FoundationModelRecordOrm(**model_in.model_dump())
            history_db.add(new_model)
            history_db.commit()

            return FoundationModelRecord.model_validate(new_model)


class LlamaCppProvider(BaseProvider):
    search_dir: str

    loaded_models: dict[FoundationModelRecordID, _OneModel] = {}
    max_loaded_models: int

    def __init__(
            self,
            search_dir: str,
            max_loaded_models: int = 3,
    ):
        self.search_dir = search_dir
        self.max_loaded_models = max_loaded_models

    async def available(self) -> bool:
        return os.path.exists(self.search_dir)

    async def make_record(self) -> ProviderRecord:
        history_db: HistoryDB = next(get_history_db())

        provider_identifiers_dict = {
            "name": "lcp",
            "directory": self.search_dir,
            "version_info": f"llama_cpp v{llama_cpp.__version__}",
        }

        provider_identifiers_dict.update(local_provider_identifiers())
        provider_identifiers = orjson.dumps(provider_identifiers_dict, option=orjson.OPT_SORT_KEYS)

        # Check for existing matches
        maybe_provider = history_db.execute(
            select(ProviderRecordOrm)
            .where(ProviderRecordOrm.identifiers == provider_identifiers)
        ).scalar_one_or_none()
        if maybe_provider is not None:
            return ProviderRecord.model_validate(maybe_provider)

        new_provider = ProviderRecordOrm(
            identifiers=provider_identifiers,
            created_at=datetime.now(tz=timezone.utc),
            machine_info=await local_fetch_machine_info(),
        )
        history_db.add(new_provider)
        history_db.commit()

        return ProviderRecord.model_validate(new_provider)

    async def _check_and_list_models(
            self,
    ) -> AsyncGenerator[FoundationModelRecord, None]:
        def _generate_filenames(rootpath):
            for dirpath, _, filenames in os.walk(rootpath, followlinks=True):
                for file in filenames:
                    if file[-5:] != '.gguf':
                        continue

                    yield os.path.abspath(os.path.join(dirpath, file))

        provider_record: ProviderRecord = await self.make_record()

        for model_path in _generate_filenames(self.search_dir):
            temp_model: _OneModel = _OneModel(model_path)
            if not await temp_model.available():
                continue

            temp_model_response: FoundationModelRecord | None
            temp_model_response = await temp_model.as_info(provider_record, os.path.abspath(self.search_dir))
            if temp_model_response is not None:
                yield temp_model_response

    async def list_models_nocache(
            self,
    ) -> AsyncGenerator[FoundationModelRecord, None]:
        """Caching version."""
        if self.cached_model_infos:
            for model_info in self.cached_model_infos:
                yield model_info

        else:
            async for model_info in self._check_and_list_models():
                yield model_info
                self.cached_model_infos.append(model_info)

    async def chat_from(
            self,
            messages_list: list[ChatMessage],
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        if inference_model.id not in self.loaded_models:
            new_model: _OneModel = _OneModel(
                os.path.abspath(os.path.join(self.search_dir,
                                             safe_get(inference_model.model_identifiers, "path")))
            )
            while len(self.loaded_models) >= self.max_loaded_models:
                # Use this elaborate syntax so we delete the _oldest_ item.
                del self.loaded_models[
                    next(iter(self.loaded_models))
                ]

            self.loaded_models[inference_model.id] = new_model

        await self.loaded_models[inference_model.id].launch()
        underlying_model: llama_cpp.Llama = self.loaded_models[inference_model.id].underlying_model

        maybe_inference_options: dict = {}
        if inference_options.inference_options:
            maybe_inference_options.update(
                orjson.loads(inference_options.inference_options)
            )

        def content_extractor(chunk: JSONDict) -> JSONDict:
            response_choices = safe_get(chunk, "choices")
            if len(response_choices) > 1:
                logger.warning(f"Received {len(response_choices)=}, ignoring all but the first")

            return response_choices[0]

        def content_consolidator(chunk: JSONDict, response: JSONDict) -> JSONDict:
            for k, v in chunk.items():
                if k not in response:
                    response[k] = v
                elif k == 'choices':
                    if len(v) > 1:
                        logger.warning(f"Received {len(v)} choices, ignoring all but the first")
                    for k3, v3 in v[0].items():
                        if k3 not in response[k]:
                            response[k][0][k3] = v3
                        elif k3 == 'delta':
                            for k4, v4 in v3.items():
                                if k4 not in response[k][0][k3]:
                                    response[k][0][k3][k4] = v4
                                elif k4 == 'content':
                                    if response[k][0][k3][k4] is None:
                                        response[k][0][k3][k4] = safe_get_arrayed(chunk, k, 0, k3, k4)
                                    else:
                                        response[k][0][k3][k4] += safe_get_arrayed(chunk, k, 0, k3, k4) or ""
                                else:
                                    if response[k][0][k3][k4] != v4:
                                        logger.debug(f"Didn't handle duplicate field: {k}[0].{k3}.{k4}={v4}")
                        else:
                            if response[k][k3] != v3:
                                logger.debug(f"Didn't handle duplicate field: {k}.{k3}={v3}")
                # TODO: Figure out why this field exists, shouldn't the order of calls prevent this?
                elif k == 'message':
                    for k2, v2 in v.items():
                        if k2 not in response[k]:
                            response[k][k2] = v2
                        elif k2 == 'content':
                            if response[k][k2] is None:
                                response[k][k2] = safe_get(chunk, k, k2)
                            else:
                                response[k][k2] += safe_get(chunk, k, k2) or ""
                        else:
                            if response[k][k2] != v2:
                                logger.debug(f"Didn't handle duplicate field: {k}.{k2}={v2}")
                else:
                    if response[k] != v:
                        logger.debug(f"Didn't handle duplicate field: {k}={v}")

            return response

        async def format_response(primordial: AsyncIterator[JSONDict]) -> AsyncIterator[JSONDict]:
            async for chunk in primordial:
                response_choices = safe_get(chunk, "choices")
                if len(response_choices) > 1:
                    logger.warning(f"Received {len(response_choices)=}, ignoring all but the first")

                # Duplicate the output into the field we expected.
                # TODO: Confirm that this is just an "OpenAI-compatible" output.
                extracted_content: str = safe_get_arrayed(response_choices, 0, 'delta', 'content')
                chunk['message'] = {
                    "role": "assistant",
                    "content": extracted_content,
                }

                yield chunk

        async def record_inference_event(consolidated_response: JSONDict):
            inference_event = InferenceEventOrm(
                model_record_id=inference_model.id,
                prompt_with_templating=None,
                reason="LlamaCppProvider.chat_from",
                response_created_at=datetime.now(tz=timezone.utc),
                response_error="[not implemented, no stats available]",
            )

            if safe_get(consolidated_response, "usage", "prompt_tokens"):
                inference_event.prompt_tokens = safe_get(consolidated_response, "usage", "prompt_tokens")
            if safe_get(consolidated_response, "usage", "completion_tokens"):
                inference_event.response_tokens = safe_get(consolidated_response, "usage", "completion_tokens")

            try:
                history_db.add(inference_event)
                history_db.commit()
            except sqlalchemy.exc.SQLAlchemyError:
                logger.exception(f"Failed to commit {inference_event}")
                history_db.rollback()

        # Main function body: wrap up
        iterator_or_completion: (
                llama_cpp.CreateChatCompletionResponse | Iterator[llama_cpp.CreateChatCompletionStreamResponse])
        iterator_or_completion = underlying_model.create_chat_completion(
            messages=[m.model_dump() for m in messages_list],
            stream=True,
            **maybe_inference_options,
        )

        if isinstance(iterator_or_completion, Iterator):
            iter0: Iterator[JSONDict] = iterator_or_completion
            iter1: AsyncIterator[JSONDict] = to_async(iter0)
        else:
            async def async_wrapper() -> AsyncIterator[JSONDict]:
                yield content_extractor(iterator_or_completion)

            iter1: AsyncIterator[JSONDict] = async_wrapper()

        iter2: AsyncIterator[JSONDict] = consolidate_and_call(
            iter1, content_consolidator, {},
            record_inference_event)
        iter3: AsyncIterator[JSONDict] = format_response(iter2)

        return iter3
