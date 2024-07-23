import functools
import logging
import os
from datetime import datetime, timezone
from typing import AsyncGenerator, AsyncIterator, Iterator, TypeVar, Any, Callable, Union

import llama_cpp
import orjson
import sqlalchemy
from llama_cpp import ChatCompletionRequestMessage, CreateCompletionResponse, CreateCompletionStreamResponse, \
    BaseLlamaCache, LlamaRAMCache, LlamaDiskCache
from llama_cpp.llama_chat_format import ChatFormatter, ChatFormatterResponse
from sqlalchemy import select

from _util.json import JSONDict, safe_get, safe_get_arrayed
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import FoundationModelRecordID, ChatSequenceID, TemplatedPromptText, FoundationModelHumanID
from audit.http import AuditDB
from client.database import HistoryDB, get_db as get_history_db
from client.message import ChatMessage, ChatMessageOrm
from client.sequence import ChatSequenceOrm
from client.sequence_get import fetch_messages_for_sequence
from inference.iterators import to_async, consolidate_and_yield, tee_to_console_output
from inference.logging import construct_assistant_message
from providers.foundation_models.orm import FoundationModelRecord, FoundationModelAddRequest, \
    lookup_foundation_model_detailed, FoundationModelRecordOrm, InferenceEventOrm
from providers.orm import ProviderRecord, ProviderRecordOrm
from providers.registry import BaseProvider, InferenceOptions
from providers_registry._util import local_provider_identifiers, local_fetch_machine_info

logger = logging.getLogger(__name__)


class TemplateApplier(ChatFormatter):
    """
    The contents of this mirror llama_cpp.Llama.create_chat_completion.
    This is necessary because we provide a template override.

    # If we don't have any overrides set, prefer to just use whatever `llama-cpp-python` provides.
    # Note that we are undoing all the work it does to wrap formatters as completions
    # in order to get our own copy of the template-applied prompt.

    Note that this is extremely messy, since we're re-implementing a lot of custom tweaks.
    """

    underlying_model: llama_cpp.Llama
    inference_options: InferenceOptions

    jinja_templator: ChatFormatter

    def __init__(
            self,
            underlying_model: llama_cpp.Llama,
            inference_options: InferenceOptions,
    ):
        self.underlying_model = underlying_model
        self.inference_options = inference_options

        # Read a template from… somewhere.
        alternative_template_choices = dict(
            (name[10:], template)
            for name, template in self.underlying_model.metadata.items()
            if name.startswith("tokenizer.chat_template."))
        if len(alternative_template_choices) > 0:
            logger.warning(f"{alternative_template_choices.keys()=}")

        template = (
                self.inference_options.override_model_template
                or self.underlying_model.metadata["tokenizer.chat_template"]
        )

        eos_token_id = self.underlying_model.token_eos()
        bos_token_id = self.underlying_model.token_bos()

        jinja_formatter_kwargs = {
            "template": template,
            "eos_token": self.underlying_model._model.token_get_text(eos_token_id) if eos_token_id != -1 else "",
            "bos_token": self.underlying_model._model.token_get_text(bos_token_id) if bos_token_id != -1 else "",
            "stop_token_ids": [eos_token_id],
        }

        self.jinja_templator = llama_cpp.llama_chat_format.Jinja2ChatFormatter(**jinja_formatter_kwargs)

    @staticmethod
    def chat_formatter_for(chat_format: str) -> Union[Callable, None]:
        """
        This scans for most of the functions annotated with `@register_chat_format`
        """
        formatter_name: str = f"format_{chat_format}"
        names_to_check = [
            formatter_name,
            formatter_name.replace("-", ""),
            formatter_name.replace("-", "_"),
        ]
        for name in names_to_check:
            if hasattr(llama_cpp.llama_chat_format, name):
                logger.debug(f"Found built-in chat format handler: {name}")
                formatter_fn = getattr(llama_cpp.llama_chat_format, name)
                return formatter_fn

    def llama_cpp_templating(
            self,
            messages: list[ChatCompletionRequestMessage],
    ) -> ChatFormatterResponse | None:
        cfr: ChatFormatterResponse | None = None

        formatter_fn = TemplateApplier.chat_formatter_for(self.underlying_model.chat_format)
        if formatter_fn is not None:
            cfr = formatter_fn(messages)

        if cfr is not None:
            cfr.prompt += self.inference_options.seed_assistant_response

        return cfr

    def custom_templating(
            self,
            messages: list[ChatCompletionRequestMessage],
    ) -> ChatFormatterResponse:
        cfr: ChatFormatterResponse = self.jinja_templator(messages=messages)

        # Build custom args for different `@register_chat_formats` formats.
        if self.underlying_model.chat_format == "llama-3":
            cfr.stop = "<|eot_id|>"

        # Given how most .gguf templates seem to work, we can just append the seed response,
        # instead of doing anything fancy like embedding a magic token and then truncating the templated text there.
        cfr.prompt += self.inference_options.seed_assistant_response

        return cfr


    def __call__(
            self,
            *,
            messages: list[ChatCompletionRequestMessage],
            **kwargs: Any,
    ) -> ChatFormatterResponse:
        if self.inference_options.override_model_template or self.inference_options.override_system_prompt:
            logger.debug(f"Found custom inference options, switching to custom templating: {self.underlying_model.chat_format}")
            return self.custom_templating(messages)
        else:
            maybe_cfr: ChatFormatterResponse | None = self.llama_cpp_templating(messages)
            if maybe_cfr is not None:
                return maybe_cfr
            else:
                logger.debug(f"Couldn't find chat format handler, falling back to .gguf template for: {self.underlying_model.chat_format}")
                cfr: ChatFormatterResponse = self.jinja_templator(messages=messages)
                cfr.prompt += self.inference_options.seed_assistant_response
                return cfr


class _OneModel:
    model_path: str
    shared_cache: BaseLlamaCache | None
    underlying_model: llama_cpp.Llama | None = None

    def __init__(
            self,
            model_path: str,
            shared_cache: BaseLlamaCache | None = None,
    ):
        self.model_path = model_path
        self.shared_cache = shared_cache

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

        self.underlying_model.set_cache(self.shared_cache)

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

    @property
    def model_name(self) -> FoundationModelHumanID | None:
        if self.underlying_model is None:
            return None

        return (
                safe_get(self.underlying_model.metadata, "general.name")
                or os.path.basename(self.model_path)
        )

    async def do_completion(
            self,
            prompt: TemplatedPromptText,
            lcp_inference_options: dict,
    ) -> CreateCompletionResponse | Iterator[CreateCompletionStreamResponse]:
        await self.launch()

        tokenized_prompt: list[int] = self.underlying_model.tokenize(
            prompt.encode('utf-8'),
        )
        logger.debug(f"LlamaCppProvider starting inference on model \"{self.model_name}\""
                     f" with prompt size of {len(tokenized_prompt)} tokens")

        # TODO: Confirm that reset_timings clears the `load time` from output stats.
        llama_cpp.llama_reset_timings(self.underlying_model.ctx)

        # Then return something that can kickstart generation
        return self.underlying_model.create_completion(
            tokenized_prompt,
            **lcp_inference_options,
        )

    async def convert_chat_to_completion(
            self,
            messages: list[ChatCompletionRequestMessage],
            inference_options: InferenceOptions,
    ) -> (ChatFormatterResponse, Iterator[CreateCompletionStreamResponse]):
        templator = TemplateApplier(self.underlying_model, inference_options)
        cfr: ChatFormatterResponse = templator(messages=messages)

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

        token_generator: Iterator[CreateCompletionStreamResponse] = await self.do_completion(
            cfr.prompt,
            lcp_inference_options,
        )

        return cfr, token_generator


class LlamaCppProvider(BaseProvider):
    search_dir: str

    loaded_models: dict[FoundationModelRecordID, _OneModel] = {}
    max_loaded_models: int

    shared_cache: BaseLlamaCache | None = None

    def __init__(
            self,
            search_dir: str,
            cache_dir: str | None,
            max_loaded_models: int = 3,
    ):
        super().__init__()
        self.search_dir = search_dir
        self.max_loaded_models = max_loaded_models

        if LlamaCppProvider.shared_cache is None:
            # TODO: These may not be thread/process safe, but whether _that_ matters depends on the ASGI framework
            if cache_dir is not None and os.path.isdir(cache_dir):
                LlamaCppProvider.shared_cache = LlamaDiskCache(cache_dir, capacity_bytes=32 * (1 << 30))
            else:
                LlamaCppProvider.shared_cache = LlamaRAMCache(capacity_bytes=4 * (1 << 30))

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
        """
        Caching version. The `_nocache` suffix in the title
        """
        if self.cached_model_infos:
            for model_info in self.cached_model_infos:
                yield model_info

        else:
            async for model_info in self._check_and_list_models():
                yield model_info
                self.cached_model_infos.append(model_info)

    async def _load_model(
            self,
            inference_model: FoundationModelRecordOrm,
            status_holder: ServerStatusHolder,
    ) -> _OneModel:
        if inference_model.id not in self.loaded_models:
            new_model: _OneModel = _OneModel(
                os.path.abspath(os.path.join(self.search_dir,
                                             safe_get(inference_model.model_identifiers, "path"))),
                shared_cache=LlamaCppProvider.shared_cache,
            )
            while len(self.loaded_models) >= self.max_loaded_models:
                # Use this elaborate syntax so we delete the _oldest_ item.
                del self.loaded_models[
                    next(iter(self.loaded_models))
                ]

            self.loaded_models[inference_model.id] = new_model

        if self.loaded_models[inference_model.id].underlying_model is None:
            with StatusContext(f"{self.loaded_models[inference_model.id].model_name}: loading model", status_holder):
                await self.loaded_models[inference_model.id].launch()

        return self.loaded_models[inference_model.id]

    # region Actual chat completion endpoints
    async def _do_chat_nolog(
            self,
            messages_list: list[ChatMessage],
            loaded_model: _OneModel,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
    ) -> (ChatFormatterResponse, AsyncIterator[JSONDict]):
        def chat_completion_choice0_extractor(chunk: JSONDict) -> str:
            response_choices = safe_get(chunk, "choices")
            if len(response_choices) > 1:
                logger.warning(f"Received {len(response_choices)=}, ignoring all but the first")

            return safe_get_arrayed(response_choices, 0, 'delta', 'content')

        def normal_completion_choice0_extractor(chunk: JSONDict) -> str:
            response_choices = safe_get(chunk, "choices")
            if len(response_choices) > 1:
                logger.warning(f"Received {len(response_choices)=}, ignoring all but the first")

            return safe_get_arrayed(response_choices, 0, 'text')

        async def format_response(primordial: AsyncIterator[str]) -> AsyncIterator[JSONDict]:
            async for extracted_content in primordial:
                yield {
                    "message": {
                        "role": "assistant",
                        "content": extracted_content,
                    },
                    "done": False,
                    "status": status_holder.get(),
                }

        T = TypeVar('T')

        async def update_status_and_log_info(primordial: AsyncIterator[T]) -> AsyncIterator[T]:
            async for chunk in primordial:
                yield chunk

                timings: llama_cpp.llama_timings = llama_cpp.llama_get_timings(loaded_model.underlying_model.ctx)
                status_holder.set(f"{loaded_model.model_name}: {timings.n_p_eval} new prompt tokens"
                                  f" => {timings.n_eval} tokens generated in {timings.t_eval_ms / 1000:_.3f} seconds")

            if self.shared_cache is not None:
                logger.debug(f"Updated LlamaCache size: {self.shared_cache.cache_size:_} bytes")

        # Main function body: maybe apply templating + kick off inference
        use_custom_templator: bool = True
        for message in messages_list:
            # TODO: Update this once we have an actual format for storing image uploads
            if hasattr(message, "images"):
                use_custom_templator = False

        if use_custom_templator:
            # This branch unwraps the code within llama_cpp, so we can do our custom assistant response seed etc etc
            cfr: ChatFormatterResponse
            iter0: Iterator[JSONDict]

            cfr, iter0 = await loaded_model.convert_chat_to_completion(
                messages=[m.model_dump() for m in messages_list],
                inference_options=inference_options,
            )
            iter1: Iterator[str] = map(normal_completion_choice0_extractor, iter0)
            iter2: AsyncIterator[str] = to_async(iter1)

        else:
            cfr: ChatFormatterResponse = ChatFormatterResponse(prompt="")

            lcp_inference_options: dict = {
                # Stream by default; we can handle non-streaming with the same infrastructure, just not as pretty.
                "stream": True,
            }
            if inference_options.inference_options:
                lcp_inference_options.update(
                    orjson.loads(inference_options.inference_options)
                )

            iterator_or_completion: \
                llama_cpp.CreateChatCompletionResponse | Iterator[llama_cpp.CreateChatCompletionStreamResponse]
            underlying_model: llama_cpp.Llama = loaded_model.underlying_model
            iterator_or_completion = underlying_model.create_chat_completion(
                messages=[m.model_dump() for m in messages_list],
                **lcp_inference_options,
            )

            if isinstance(iterator_or_completion, Iterator):
                iter0: Iterator[JSONDict] = iterator_or_completion
                iter1: Iterator[str] = map(normal_completion_choice0_extractor, iter0)
                iter2: AsyncIterator[str] = to_async(iter1)
            else:
                async def one_chunk_to_async() -> AsyncIterator[str]:
                    yield chat_completion_choice0_extractor(iterator_or_completion)

                iter2: AsyncIterator[str] = one_chunk_to_async()

        iter3: AsyncIterator[JSONDict] = format_response(iter2)
        iter4: AsyncIterator[JSONDict] = tee_to_console_output(iter3,
                                                               lambda chunk: safe_get(chunk, "message", "content"))
        iter5: AsyncIterator[JSONDict] = update_status_and_log_info(iter4)
        return cfr, iter5

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
        _, iter3 = await self._do_chat_nolog(
            messages_list,
            await self._load_model(inference_model, status_holder),
            inference_options,
            status_holder,
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
                if k == 'status':
                    continue
                elif k not in response:
                    response[k] = v
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
                response_info=consolidated_response,
                reason="LlamaCppProvider.do_chat_logged",
            )

            timings: llama_cpp.llama_timings = llama_cpp.llama_get_timings(
                self.loaded_models[inference_model.id].underlying_model.ctx)

            inference_event.prompt_tokens = timings.n_p_eval
            inference_event.prompt_eval_time = timings.t_p_eval_ms / 1000.
            inference_event.response_tokens = timings.n_eval
            inference_event.response_eval_time = timings.t_eval_ms / 1000.

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
            await self._load_model(inference_model, status_holder),
            inference_options,
            status_holder,
        )
        iter5: AsyncIterator[JSONDict] = consolidate_and_yield(
            iter3, content_consolidator, {},
            functools.partial(append_response_chunk, cfr=cfr))

        return iter5

# endregion
