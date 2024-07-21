import functools
import logging
import os
from datetime import datetime, timezone
from typing import AsyncGenerator, AsyncIterator, Iterator

import llama_cpp
import orjson
import sqlalchemy
from llama_cpp import ChatCompletionRequestMessage, CreateCompletionResponse, CreateCompletionStreamResponse
from llama_cpp.llama_chat_format import ChatFormatter, ChatFormatterResponse
from sqlalchemy import select

from _util.json import JSONDict, safe_get, safe_get_arrayed
from _util.status import ServerStatusHolder
from _util.typing import FoundationModelRecordID, ChatSequenceID, TemplatedPromptText
from audit.http import AuditDB
from client.database import HistoryDB, get_db as get_history_db
from client.message import ChatMessage, ChatMessageOrm
from client.sequence import ChatSequenceOrm
from client.sequence_get import fetch_messages_for_sequence
from inference.iterators import to_async, consolidate_and_yield
from inference.logging import construct_assistant_message
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
            verbose: bool = True,
    ):
        if self.underlying_model is not None:
            return

        logger.info(f"Loading llama_cpp model: {self.model_path}")
        self.underlying_model = llama_cpp.Llama(
            model_path=self.model_path,
            n_gpu_layers=-1,
            verbose=verbose,
            # TODO: Figure out a more elegant way to decide the max.
            n_ctx=4_096,
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
            # Exception usually happens because we loaded an invalid .gguf file; ignore it.
            logger.warning(e)
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

    async def generate(
            self,
            prompt: TemplatedPromptText,
            lcp_inference_options: dict,
    ) -> CreateCompletionResponse | Iterator[CreateCompletionStreamResponse]:
        await self.launch()
        tokenized_prompt: list[int] = self.underlying_model.tokenize(
            prompt.encode('utf-8'),
        )

        return self.underlying_model.create_completion(
            tokenized_prompt,
            **lcp_inference_options,
        )

    async def convert_chat_to_generate(
            self,
            messages: list[ChatCompletionRequestMessage],
            inference_options: InferenceOptions,
    ) -> (ChatFormatterResponse, Iterator[CreateCompletionStreamResponse]):
        # Read a template from… somewhere.
        alternative_template_choices = dict(
            (name[10:], template)
            for name, template in self.underlying_model.metadata.items()
            if name.startswith("tokenizer.chat_template."))
        if len(alternative_template_choices) > 0:
            logger.warning(f"{alternative_template_choices.keys()=}")

        template = (
                inference_options.override_model_template
                or self.underlying_model.metadata["tokenizer.chat_template"]
        )

        eos_token_id = self.underlying_model.token_eos()
        bos_token_id = self.underlying_model.token_bos()

        eos_token = self.underlying_model._model.token_get_text(eos_token_id) if eos_token_id != -1 else ""
        bos_token = self.underlying_model._model.token_get_text(bos_token_id) if bos_token_id != -1 else ""

        templator: ChatFormatter = llama_cpp.llama_chat_format.Jinja2ChatFormatter(
            template=template,
            eos_token=eos_token,
            bos_token=bos_token,
            stop_token_ids=[eos_token_id],
        )

        # Apply the template
        cfr: ChatFormatterResponse = templator(
            messages=messages,
        )

        # Given how most .gguf templates seem to work, we can just append the seed response,
        # instead of doing anything fancy like embedding a magic token and then truncating the templated text there.
        cfr.prompt += inference_options.seed_assistant_response

        # Update default inference options with the provided values.
        lcp_inference_options = {
            "max_tokens": None,
            "stream": True,
            "stop": cfr.stop,
            "stopping_criteria": cfr.stopping_criteria,
        }
        lcp_inference_options.update(
            orjson.loads(inference_options.inference_options or "{}")
        )

        result: Iterator[CreateCompletionStreamResponse] = await self.generate(
            cfr.prompt,
            lcp_inference_options,
        )
        return cfr, result


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

    # region Actual chat completion endpoints
    async def _do_chat_nolog(
            self,
            messages_list: list[ChatMessage],
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
            use_custom_templater: bool = True,
    ) -> (ChatFormatterResponse, AsyncIterator[JSONDict]):
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

        def choice0_extractor(chunk: JSONDict) -> JSONDict:
            response_choices = safe_get(chunk, "choices")
            if len(response_choices) > 1:
                logger.warning(f"Received {len(response_choices)=}, ignoring all but the first")

            return response_choices[0]

        async def format_response(primordial: AsyncIterator[JSONDict]) -> AsyncIterator[JSONDict]:
            async for chunk in primordial:
                response_choices = safe_get(chunk, "choices")
                if len(response_choices) > 1:
                    logger.warning(f"Received {len(response_choices)=}, ignoring all but the first")

                # TODO: Confirm that this is just an "OpenAI-compatible" output.
                extracted_content: str | None = (
                    # This is for chat completions
                        safe_get_arrayed(response_choices, 0, 'delta', 'content')
                        # This is for normal, template pre-applied completions
                        or safe_get_arrayed(response_choices, 0, 'text')
                )

                # Duplicate the output into the field we expected.
                chunk['message'] = {
                    "role": "assistant",
                    "content": extracted_content or "",
                }

                yield chunk

        # Main function body: wrap up
        if use_custom_templater:
            # This branch unwraps the code within llama_cpp, so we can do our custom assistant response seed etc etc
            cfr: ChatFormatterResponse
            iter0: Iterator[JSONDict]

            cfr, iter0 = await self.loaded_models[inference_model.id].convert_chat_to_generate(
                messages=[m.model_dump() for m in messages_list],
                inference_options=inference_options,
            )
            iter1: AsyncIterator[JSONDict] = to_async(iter0)

        else:
            cfr: ChatFormatterResponse = ChatFormatterResponse(prompt="")

            lcp_inference_options: dict = {}
            if inference_options.inference_options:
                lcp_inference_options.update(
                    orjson.loads(inference_options.inference_options)
                )

            iterator_or_completion: \
                llama_cpp.CreateChatCompletionResponse | Iterator[llama_cpp.CreateChatCompletionStreamResponse]
            underlying_model: llama_cpp.Llama = self.loaded_models[inference_model.id].underlying_model
            iterator_or_completion = underlying_model.create_chat_completion(
                messages=[m.model_dump() for m in messages_list],
                stream=True,
                **lcp_inference_options,
            )

            if isinstance(iterator_or_completion, Iterator):
                iter0: Iterator[JSONDict] = iterator_or_completion
                iter1: AsyncIterator[JSONDict] = to_async(iter0)
            else:
                async def async_wrapper() -> AsyncIterator[JSONDict]:
                    yield choice0_extractor(iterator_or_completion)

                iter1: AsyncIterator[JSONDict] = async_wrapper()

        iter2: AsyncIterator[JSONDict] = format_response(iter1)
        return cfr, iter2

    async def do_chat_nolog(
            self,
            messages_list: list[ChatMessage],
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        iter3: AsyncIterator[JSONDict]
        _, iter3 = self._do_chat_nolog(
            messages_list, inference_model, inference_options, status_holder, history_db, audit_db,
        )
        return iter3

    async def do_chat_logged(
            self,
            sequence_id: ChatSequenceID,
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
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

        def record_inference_event(
                consolidated_response: JSONDict,
                cfr: ChatFormatterResponse,
        ) -> InferenceEventOrm:
            inference_event = InferenceEventOrm(
                model_record_id=inference_model.id,
                prompt_with_templating=cfr.prompt,
                response_created_at=datetime.now(tz=timezone.utc),
                response_error="[not implemented yet]",
                response_info=consolidated_response,
                reason="LlamaCppProvider.chat_from",
            )

            if safe_get(consolidated_response, "usage", "prompt_tokens"):
                inference_event.prompt_tokens = safe_get(consolidated_response, "usage", "prompt_tokens")
            if safe_get(consolidated_response, "usage", "completion_tokens"):
                inference_event.response_tokens = safe_get(consolidated_response, "usage", "completion_tokens")

            history_db.add(inference_event)
            history_db.commit()

            return inference_event

        async def append_response_chunk(
                consolidated_response: JSONDict,
                cfr: ChatFormatterResponse,
        ) -> AsyncIterator[JSONDict]:
            # And now, construct the ChatSequence (which references the InferenceEvent, actually)
            try:
                inference_event: InferenceEventOrm = record_inference_event(consolidated_response, cfr)

                # Return a chunk that includes the entire context-y prompt.
                # This is marked a separate packet to guard against overflows and similar.
                yield {
                    "prompt_with_templating": cfr.prompt,
                }

                response_message: ChatMessageOrm | None = construct_assistant_message(
                    inference_options.seed_assistant_response,
                    safe_get(consolidated_response, "message", "content"),
                    inference_event.response_created_at,
                    history_db,
                )
                if not response_message:
                    return

                original_sequence: ChatSequenceOrm = history_db.execute(
                    select(ChatSequenceOrm)
                    .where(ChatSequenceOrm.id == sequence_id)
                ).scalar_one()

                # TODO: Replace with `construct_new_sequence_from`
                response_sequence = ChatSequenceOrm(
                    human_desc=original_sequence.human_desc,
                    user_pinned=False,
                    current_message=response_message.id,
                    parent_sequence=original_sequence.id,
                )

                history_db.add(response_sequence)

                response_sequence.generated_at = inference_event.response_created_at
                response_sequence.generation_complete = True
                response_sequence.inference_job_id = inference_event.id
                if inference_event.response_error:
                    response_sequence.inference_error = inference_event.response_error

                history_db.commit()

                # And complete the circular reference that really should be handled in the SQLAlchemy ORM
                inference_job = history_db.merge(inference_event)
                inference_job.parent_sequence = response_sequence.id

                history_db.add(inference_job)
                history_db.commit()

                # Return fields that the client probably cares about
                yield {
                    "new_message_id": response_sequence.current_message,
                    "new_sequence_id": response_sequence.id,
                    "done": True,
                }

            except sqlalchemy.exc.SQLAlchemyError:
                logger.exception(f"Failed to create add-on ChatSequence from {consolidated_response}")
                history_db.rollback()
                status_holder.set(f"Failed to create add-on ChatSequence from {consolidated_response}")
                yield {
                    "error": "Failed to create add-on ChatSequence",
                    "done": True,
                }

            except Exception:
                logger.exception(f"Failed to create add-on ChatSequence from {consolidated_response}")
                status_holder.set(f"Failed to create add-on ChatSequence from {consolidated_response}")
                yield {
                    "error": "Failed to create add-on ChatSequence",
                    "done": True,
                }

        messages_list: list[ChatMessage] = fetch_messages_for_sequence(sequence_id, history_db)

        iter3: AsyncIterator[JSONDict]
        cfr, iter3 = await self._do_chat_nolog(
            messages_list,
            inference_model,
            inference_options,
            status_holder,
            history_db,
            audit_db,
        )
        iter5: AsyncIterator[JSONDict] = consolidate_and_yield(
            iter3, content_consolidator, {},
            functools.partial(append_response_chunk, cfr=cfr))

        return iter5

# endregion
