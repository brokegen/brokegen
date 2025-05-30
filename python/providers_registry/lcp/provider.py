import asyncio
import ctypes
import functools
import json
import logging
import os
from datetime import datetime, timezone
from typing import AsyncGenerator, AsyncIterator, Iterator, TypeVar, Any, Callable, Union, Awaitable

import jinja2.exceptions
import jsondiff
import llama_cpp
import orjson
import psutil
import sqlalchemy
from jinja2 import TemplateSyntaxError
from llama_cpp import ChatCompletionRequestMessage, CreateCompletionStreamResponse, \
    ChatCompletionRequestSystemMessage
from llama_cpp.llama_chat_format import ChatFormatter, ChatFormatterResponse
from sqlalchemy import select

from _util.json import JSONDict, safe_get, safe_get_arrayed
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import FoundationModelRecordID, ChatSequenceID, FoundationModelHumanID, PromptText
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
                or safe_get(self.underlying_model.metadata, "tokenizer.chat_template")
        )
        if template is None:
            raise ValueError(f"No chat_template found for {self.underlying_model}")

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

        return None

    def llama_cpp_templating(
            self,
            messages: list[ChatCompletionRequestMessage],
    ) -> ChatFormatterResponse | None:
        cfr: ChatFormatterResponse | None = None

        formatter_fn = TemplateApplier.chat_formatter_for(self.underlying_model.chat_format)
        if formatter_fn is None:
            is_mistral_nemo: bool = safe_get(self.underlying_model.metadata,"general.name") == "Mistral Nemo Instruct 2407"
            if is_mistral_nemo:
                formatter_fn = TemplateApplier.chat_formatter_for("mistral-instruct")

        if formatter_fn is not None:
            cfr = formatter_fn(messages)

        if cfr is not None:
            cfr.prompt += (self.inference_options.seed_assistant_response or "")

        return cfr

    def custom_templating(
            self,
            messages: list[ChatCompletionRequestMessage],
    ) -> ChatFormatterResponse:
        cfr: ChatFormatterResponse = self.jinja_templator(messages=messages)

        if self.underlying_model.chat_format == "llama-3":
            cfr.stop = "<|eot_id|>"

        else:
            basename: str = safe_get(self.underlying_model.metadata, "general.basename")
            if basename == "Meta-Llama-3.1":
                cfr.stop = ["<|eot_id|>", "<|eot_id>"]

        # Given how most .gguf templates seem to work, we can just append the seed response,
        # instead of doing anything fancy like embedding a magic token and then truncating the templated text there.
        cfr.prompt += (self.inference_options.seed_assistant_response or "")

        return cfr

    def __call__(
            self,
            *,
            messages: list[ChatCompletionRequestMessage],
            **kwargs: Any,
    ) -> ChatFormatterResponse:
        # If we have a special "system" prompt, override the first system message in our list
        messages_with_system = list(messages)
        if self.inference_options.override_system_prompt is not None:
            if len(messages_with_system) >= 1 and messages_with_system[0]["role"] == "system":
                messages_with_system[0]["content"] = self.inference_options.override_system_prompt
            else:
                messages_with_system.insert(0, {
                    "role": "system",
                    "content": self.inference_options.override_system_prompt,
                })

        use_custom_template = self.inference_options.override_model_template
        basename: str = safe_get(self.underlying_model.metadata, "general.basename")
        if basename == "Meta-Llama-3.1":
            use_custom_template = True

        # First option: use our custom overrides
        if use_custom_template:
            # logger.debug(f"Switching to custom templating: {self.underlying_model.chat_format}")
            return self.custom_templating(messages)

        # Second: pick up whatever llama_cpp_python has
        maybe_cfr: ChatFormatterResponse | None = self.llama_cpp_templating(messages)
        if maybe_cfr is not None:
            return maybe_cfr

        # Third: read settings from .gguf file
        cfr: ChatFormatterResponse = self.jinja_templator(messages=messages)
        cfr.prompt += self.inference_options.seed_assistant_response or ""
        return cfr


class _OneModel:
    model_path: str
    underlying_model: llama_cpp.Llama | None
    underlying_context_params: dict

    def __init__(
            self,
            model_path: str,
    ):
        self.model_path = model_path
        self.underlying_model = None
        self.underlying_context_params = {}

    def launch_with_params(
            self,
            cfr: ChatFormatterResponse | None,
            inference_options: InferenceOptions,
    ) -> dict:
        context_params = {
            "model_path": self.model_path,
            "n_ctx": 512,

            # TODO: This is not yet present as of llama-cpp-python v0.3.5
            #
            # - llama_cpp.py: add `no_perf` to class llama_context_params
            # - llama.py add argument + use in Llama.__init__()
            #
            "no_perf": False,
        }

        parsed_inference_options = {}
        try:
            parsed_inference_options = orjson.loads(inference_options.inference_options)
        except ValueError:
            if inference_options.inference_options:
                logger.warning(f"Invalid inference options, ignoring: \"{inference_options.inference_options}\"")

        context_fields: list[str] = [field for field, _ in llama_cpp.llama_context_params._fields_]
        # Additional fields that are only present in __init__
        context_fields.extend([
            # Model Params
            "n_gpu_layers",
            "split_mode",
            "main_gpu",
            "tensor_split",
            "rpc_servers",
            "vocab_only",
            "use_mmap",
            "use_mlock",
            "kv_overrides",
            # Sampling Params
            "last_n_tokens_size",
            # LoRA Params
            "lora_base",
            "lora_scale",
            "lora_path",
            # Backend Params
            "numa",
            # Chat Format Params
            "chat_format",
            "chat_handler",
            # Speculative Decoding
            "draft_model",
            # Tokenizer Override
            "tokenizer",
            # KV cache quantization
            "type_k",
            "type_v",
            # Misc
            "spm_infill",
            "verbose",
        ])

        for field in context_fields:
            if field in parsed_inference_options:
                context_params[field] = parsed_inference_options[field]
                del parsed_inference_options[field]

        # If we already loaded a model, confirm that our context_params are compatible
        if self.underlying_model is not None:
            if context_params != self.underlying_context_params:
                try:
                    # DEBUG: Print the details about what's different.
                    diff_info: str = json.dumps(
                        # The values in the second dict are what get printed out.
                        jsondiff.diff(self.underlying_context_params, context_params),
                        indent=2
                    )
                    logger.info(f"Supplied context_params differ, reloading: {diff_info}")
                except Exception:
                    # TODO: This mostly happens because there's a "Symbol" key in the JSON somewhere
                    logger.info(f"Supplied context_params differ, reloading: {context_params}")

                self.underlying_model = None

        if self.underlying_model is None:
            logger.info(f"Loading llama_cpp model: {self.model_name}")
            self.underlying_model = llama_cpp.Llama(**context_params)
            self.underlying_context_params = context_params

        # Update default inference options with the provided values.
        if cfr is None:
            templator = TemplateApplier(self.underlying_model, inference_options)
            cfr: ChatFormatterResponse = templator(messages=[
                ChatCompletionRequestSystemMessage(role="system", content="[throwaway message for stop tokens]]"),
            ])

        model_params = {
            "max_tokens": None,
            "stream": True,
            "stop": cfr.stop,
            "stopping_criteria": cfr.stopping_criteria,
        }
        model_params.update(parsed_inference_options)

        # logger.debug(f"Chat format for {self.model_name}: {self.underlying_model.chat_format}")
        return model_params

    def available(self) -> bool:
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
        except (ValueError, TemplateSyntaxError) as e:
            # Exception usually happens because we loaded an invalid .gguf file; ignore it.
            logger.warning(e)
            return False

        tokenized: list[int] = just_tokens.tokenize(sample_text)
        detokenized: bytes = just_tokens.detokenize(tokenized)

        return sample_text == detokenized

    def as_info(
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

        # Read the model_identifiers
        model_identifiers = info_only.metadata
        # TODO: This shouldn't be part of the unique identifiers, but then, what would?
        model_identifiers["path"] = os.path.relpath(self.model_path, path_prefix)
        model_identifiers = orjson.loads(
            # Keep these sorted in alphabetical order, for consistency
            orjson.dumps(model_identifiers, option=orjson.OPT_SORT_KEYS)
        )

        # Read the model_params into combined_inference_params,
        # since they only affect inference, but don't impact the model
        model_params = dict([
            (field, getattr(info_only.model_params, field))
            for field, _ in info_only.model_params._fields_
        ])
        for k, v in list(model_params.items()):
            if v is None:
                model_params[k] = None
            elif isinstance(v, (bool, int)):
                model_params[k] = v
            elif k == "tensor_split":
                if v:
                    v: ctypes.Array[ctypes.c_float]
                    # TODO: Verify that this evaluates correctly
                    model_params[k] = list(v)
                else:
                    model_params[k] = None
            elif k == "kv_overrides":
                if v:
                    v: ctypes.Array[llama_cpp.llama_model_kv_override]
                    # TODO: Verify that this evaluates correctly
                    model_params[k] = list(v)
                else:
                    model_params[k] = None
            # Delete runtime properties
            elif k in ("progress_callback", "progress_callback_user_data"):
                del model_params[k]
            else:
                model_params[k] = str(v)

        # Feed them into combined_inference_params
        combined_inference_params = {
            "model_params": model_params,
        }
        combined_inference_params = orjson.loads(
            # Keep these sorted, so we can actually uniquely identify them in the DB
            orjson.dumps(combined_inference_params, option=orjson.OPT_SORT_KEYS)
        )

        access_time = datetime.now(tz=timezone.utc)
        model_in = FoundationModelAddRequest(
            human_id=model_name,
            first_seen_at=access_time,
            last_seen=access_time,
            provider_identifiers=provider_record.identifiers,
            model_identifiers=model_identifiers,
            combined_inference_parameters=combined_inference_params,
        )

        history_db: HistoryDB = next(get_history_db())

        maybe_model: FoundationModelRecordID | None = lookup_foundation_model_detailed(model_in, history_db)
        if maybe_model is not None:
            maybe_model.merge_in_updates(model_in)
            history_db.add(maybe_model)
            history_db.commit()

            return FoundationModelRecord.model_validate(maybe_model)

        else:
            logger.info(f"lcp constructed a new FoundationModelRecord: {model_in.model_dump_json(indent=2)}")
            new_model = FoundationModelRecordOrm(**model_in.model_dump())
            history_db.add(new_model)
            history_db.commit()

            return FoundationModelRecord.model_validate(new_model)

    @property
    def model_name(self) -> FoundationModelHumanID | None:
        """
        For now, rely on using the .gguf filename to identify the model.
        """
        if self.underlying_model is None:
            return os.path.basename(self.model_path)

        general_name = safe_get(self.underlying_model.metadata, "general.name")
        # TODO: console output has the string we want in `llm_load_print_meta: model ftype`, but can't figure out how to access it
        model_ftype: str | None = None
        if general_name and model_ftype:
            return f"[lcp] {general_name} {model_ftype}"

        return "[lcp] " + os.path.basename(self.model_path)

    async def do_completion(
            self,
            cfr: ChatFormatterResponse,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
    ) -> tuple[
        llama_cpp.CreateCompletionResponse | Iterator[llama_cpp.CreateCompletionStreamResponse],
        int,
    ]:
        await asyncio.sleep(0)
        model_params = self.launch_with_params(cfr, inference_options)

        tokenized_prompt: list[int] = self.underlying_model.tokenize(
            cfr.prompt.encode('utf-8'),
        )
        cfr_prompt_token_len: int = len(tokenized_prompt)

        # In the normal/fast case, just run a normal completion
        if inference_options.prompt_eval_batch_size is None or inference_options.prompt_eval_batch_size <= 0:
            status_holder.push(f"\"{self.model_name}\" starting prompt eval ({cfr_prompt_token_len:_} prompt tokens) + inference")
            logger.debug(f"\"{self.model_name}\" starting prompt eval ({cfr_prompt_token_len:_} prompt tokens) + inference")
            return self.underlying_model.create_completion(
                tokenized_prompt,
                **model_params,
            ), cfr_prompt_token_len

        # Split the prompt eval into chunks, so we give the caller(s) a chance to break
        else:
            status_holder.push(f"\"{self.model_name}\" starting chunked prompt eval: {cfr_prompt_token_len:_} tokens")

            chunking_model_params = dict(model_params)
            # NB This should be 0, but 0 has a special value that means "evaluate until model stops" or something.
            # Some providers also use -1 and -2 as special values.
            chunking_model_params["max_tokens"] = 1
            chunking_model_params["stream"] = False

            start_time: datetime = datetime.now(tz=timezone.utc)
            CHUNK_SIZE: int = inference_options.prompt_eval_batch_size
            tokens_parsed: int = 0

            # To tweak the output of llama_cpp.Llama:
            suppressed_model_verbose: bool = self.underlying_model.verbose
            self.underlying_model.verbose = False

            last_tokens_parsed: int
            last_timing_print: datetime
            timing_print_interval: float = 5.0

            logger.info(f"[lcp] prompt eval will be chunked, `timings.n_eval` may be off by {cfr_prompt_token_len / CHUNK_SIZE:_.1f} tokens")
            logger.debug(f"[lcp] prompt eval: {0: >6_} of {cfr_prompt_token_len:_} tokens total, cache prefix-match and estimated total unknown")
            with StatusContext(f"[lcp] prompt eval: {cfr_prompt_token_len:_} tokens total, with batch size {CHUNK_SIZE}", status_holder):
                # Force an initial print, so we preload the model + don't compute that initial time.
                await asyncio.sleep(0)
                self.underlying_model.create_completion(tokenized_prompt[:1], **chunking_model_params)
                # Don't update tokens_parsed, because we want to stick to CHUNK_SIZE boundaries, if possible.
                start_time = datetime.now(tz=timezone.utc)
                last_tokens_parsed = 1
                last_timing_print = start_time

                while tokens_parsed < cfr_prompt_token_len:
                    await asyncio.sleep(0)
                    self.underlying_model.create_completion(tokenized_prompt[:tokens_parsed + CHUNK_SIZE], **chunking_model_params)
                    tokens_parsed = min(tokens_parsed + CHUNK_SIZE, cfr_prompt_token_len)

                    elapsed_time: float = (datetime.now(tz=timezone.utc) - start_time).total_seconds()
                    estimated_time: float = (cfr_prompt_token_len - tokens_parsed) / tokens_parsed * elapsed_time

                    status_holder.set(
                        f"[lcp] prompt eval: {tokens_parsed} of {cfr_prompt_token_len:_} tokens total"
                        f", {elapsed_time: >7_.3f} seconds elapsed + {estimated_time:_.0f}s remaining")

                    # Print similar timing info to the console, but throttled by time.
                    if suppressed_model_verbose:
                        count_since_print: int = tokens_parsed - last_tokens_parsed
                        time_since_print: float = (datetime.now(tz=timezone.utc) - last_timing_print).total_seconds()

                        if time_since_print > timing_print_interval:
                            # NB This will only be useful if caller set a max batch eval size; otherwise, only called once at end of prompt eval.
                            logger.debug(
                                f"[lcp] prompt eval: {tokens_parsed: >6_} of {cfr_prompt_token_len:_} tokens total"
                                f", {elapsed_time + estimated_time: >9_.3f} secs estimated total at {count_since_print / time_since_print: >6_.3f} tokens/sec")

                            last_tokens_parsed = tokens_parsed
                            last_timing_print = datetime.now(tz=timezone.utc)

            status_holder.push(f"\"{self.model_name}\" done with prompt eval, starting inference with {cfr_prompt_token_len:_} prompt tokens")
            self.underlying_model.verbose = suppressed_model_verbose
            return self.underlying_model.create_completion(tokenized_prompt, **model_params), cfr_prompt_token_len

    async def do_chat(
            self,
            messages: list[ChatCompletionRequestMessage],
            inference_options: InferenceOptions,
    ) -> llama_cpp.CreateChatCompletionResponse | Iterator[llama_cpp.CreateChatCompletionStreamResponse]:
        model_params = self.launch_with_params(None, inference_options)
        # This argument isn't supported by the create_chat_completion endpoint
        if "stopping_criteria" in model_params:
            del model_params["stopping_criteria"]

        # Copied from TemplateApplier.__call__()
        messages_with_system = list(messages)
        if inference_options.override_system_prompt is not None:
            if len(messages_with_system) >= 1 and messages_with_system[0]["role"] == "system":
                messages_with_system[0]["content"] = inference_options.override_system_prompt
            else:
                messages_with_system.insert(0, {
                    "role": "system",
                    "content": inference_options.override_system_prompt,
                })

        # TODO: Should these be outright errors?
        if inference_options.override_model_template:
            logger.error(f'Using llama.cpp \"chat\" endpoint, ignoring {inference_options.override_model_template=}')
        if inference_options.seed_assistant_response:
            logger.error(f'Using llama.cpp \"chat\" endpoint, ignoring {inference_options.seed_assistant_response=}')

        iterator_or_completion: \
            llama_cpp.CreateChatCompletionResponse | Iterator[llama_cpp.CreateChatCompletionStreamResponse]
        return self.underlying_model.create_chat_completion(
            messages=messages,
            **model_params,
        )


class LlamaCppProvider(BaseProvider):
    search_dir: str

    loaded_models: dict[FoundationModelRecordID, _OneModel] = {}
    max_loaded_models: int

    def __init__(
            self,
            search_dir: str,
            cache_dir: str | None,
            max_loaded_models: int,
    ):
        super().__init__()
        self.search_dir = search_dir
        self.max_loaded_models = max_loaded_models

    async def available(self) -> bool:
        return os.path.exists(self.search_dir)

    async def make_record(self) -> ProviderRecord:
        history_db: HistoryDB = next(get_history_db())

        provider_identifiers_dict = {
            "name": "lcp",
            "directory": self.search_dir,
            # We intentionally don't attach a version number because we don't want to invalidate old versions.
            # Additionally, it doesn't tell us anything about the underlying llama.cpp version, anyway.
            "version_info": f"llama_cpp_python",
        }

        provider_identifiers_dict.update(await local_provider_identifiers())
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
            if not temp_model.available():
                continue

            temp_model_response: FoundationModelRecord | None
            temp_model_response = temp_model.as_info(provider_record, os.path.abspath(self.search_dir))
            if temp_model_response is not None:
                yield temp_model_response

    async def list_models_nocache(
            self,
    ) -> AsyncGenerator[FoundationModelRecord, None]:
        """
        Caching version. The `_nocache` suffix in the title
        """
        async for model_info in self._check_and_list_models():
            yield model_info

            # Manually add a yield-ish block, to remain more responsive during loading.
            # This lets the client load ChatSequences while we're enumerating available .gguf files.
            await asyncio.sleep(0)

    def _load_model(
            self,
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
    ) -> _OneModel:
        reference_available_ram = f"{psutil.virtual_memory().available / (1 << 30):_.1f}"

        # Check whether we're running out of resources. Preemptively.
        # Interestingly enough, we only ever worry about RAM:
        #
        # - Apple silicon has unified memory
        # - Intel macOS generally doesn't have a llama.cpp-supported GPU, so it's all CPU
        #
        available_ram = psutil.virtual_memory().available / (1 << 30)
        total_ram = psutil.virtual_memory().total / (1 << 30)
        logger.info(f"Available RAM ({len(self.loaded_models)} models loaded): {available_ram:_.1f} GB / {total_ram:_.1f} total")

        # Now load the model
        target_model: _OneModel
        if inference_model.id not in self.loaded_models:
            self.trim_loaded_models(self.max_loaded_models - 1)

            new_model: _OneModel = _OneModel(
                os.path.abspath(os.path.join(self.search_dir,
                                             safe_get(inference_model.model_identifiers, "path"))),
            )

            self.loaded_models[inference_model.id] = new_model
            target_model = new_model
        else:
            target_model = self.loaded_models[inference_model.id]

        if reference_available_ram != f"{psutil.virtual_memory().available / (1 << 30):_.1f}":
            available_ram = psutil.virtual_memory().available / (1 << 30)
            total_ram = psutil.virtual_memory().total / (1 << 30)
            logger.info(f"Available RAM (post-trim): {available_ram:_.1f} GB / {total_ram:_.1f} total")

        with StatusContext(f"{inference_model.human_id}: loading model", status_holder):
            target_model.launch_with_params(None, inference_options)

            if reference_available_ram != f"{psutil.virtual_memory().available / (1 << 30):_.1f}":
                available_ram = psutil.virtual_memory().available / (1 << 30)
                total_ram = psutil.virtual_memory().total / (1 << 30)
                logger.info(f"Available RAM (post-load): {available_ram:_.1f} GB / {total_ram:_.1f} total")

            return target_model

    def trim_loaded_models(self, model_limit: int):
        while len(self.loaded_models) > model_limit:
            # Use this elaborate syntax so we delete the _oldest_ item.
            oldest_model_index: int = next(iter(self.loaded_models))
            logger.info(f"Unloading llama_cpp model: {self.loaded_models[oldest_model_index].model_name}")
            del self.loaded_models[oldest_model_index]

    #  region ----- Actual chat completion endpoints
    async def _do_chat_nolog(
            self,
            messages_list: list[ChatMessage],
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            tee_to_console: bool = False,
    ) -> (ChatFormatterResponse, AsyncIterator[JSONDict]):
        """
        Base method for llama-cpp-python-based inference.

        TODO: The initial load step can be very long (47 GB takes 75 seconds on my system),
              and the server mostly just stalls during this load. No output to the client.

              For now, clients don't really have a problem with this, it just appears like an unresponsive server.
        """
        loaded_model = self._load_model(inference_model, inference_options, status_holder)

        def chat_completion_choice0_extractor(chunk: JSONDict) -> str:
            response_choices = safe_get(chunk, "choices")
            if len(response_choices) > 1:
                logger.warning(f"Received {len(response_choices)=}, ignoring all but the first")

            return safe_get_arrayed(response_choices, 0, 'delta', 'content') or ""

        def normal_completion_choice0_extractor(chunk: JSONDict) -> str:
            response_choices = safe_get(chunk, "choices")
            if len(response_choices) > 1:
                logger.warning(f"Received {len(response_choices)=}, ignoring all but the first")

            return safe_get_arrayed(response_choices, 0, 'text') or ""

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

                if extracted_content:
                    pass

        T = TypeVar('T')

        async def update_status_and_log_info(
                primordial: AsyncIterator[T],
                cfr_prompt_token_len: int | None,
        ) -> AsyncIterator[T]:
            prompt_tokens = cfr_prompt_token_len or 0
            prompt_eval_start_time = datetime.now(tz=timezone.utc)
            prompt_eval_end_time: datetime | None = None

            response_tokens = 0
            response_eval_start_time: datetime | None = None

            try:
                async for chunk in primordial:
                    yield chunk

                    # If this is the first token we're picking up
                    if prompt_eval_end_time is None or response_eval_start_time is None:
                        reference_time = datetime.now(tz=timezone.utc)
                        prompt_eval_end_time = reference_time
                        response_eval_start_time = reference_time

                    response_tokens += 1
                    response_eval_duration = (datetime.now(tz=timezone.utc) - response_eval_start_time).total_seconds()

                    evaluation_desc: str = f"{response_tokens} tokens generated in {response_eval_duration:_.3f} seconds"

                    if cfr_prompt_token_len == 0:
                        status_holder.set(f"{inference_model.human_id}: " + evaluation_desc)
                    else:
                        status_holder.set(f"{inference_model.human_id}: {cfr_prompt_token_len} total prompt tokens => " + evaluation_desc)

            except Exception as e:
                # Probably ran out of tokens; continue on and rely on final handler(s)
                logger.exception(f"Caught exception during inference, probably out of tokens")
                if response_tokens == 0:
                    yield {
                        "error": f"{type(e)}: {e}",
                        "done": False,
                        "status": status_holder.get(),
                    }

            # Add an error message if we _probably_ ran out of tokens.
            # It's okay to mark it as an error + toss previous work because the user wants a not-truncated response.
            if response_tokens > 0:
                # For some kind of error margin, complain if we're within 10 tokens of the end.
                # This doesn't work well for extremely short contexts, but for ten tokens? blame the user.
                #
                # This "safety" margin can probably reduced to 1 or 2, depending on whether we have Unicode sequences
                # that span multiple tokens (the llama-cpp-python decoder groups them together).
                #
                tokens_remaining = loaded_model.underlying_model.context_params.n_ctx - cfr_prompt_token_len - response_tokens
                if tokens_remaining < 0:
                    # NB This happens fairly often, especially for long text like transcript summaries.
                    logger.debug(f"{tokens_remaining:_} token overflow for total context size of {loaded_model.underlying_model.context_params.n_ctx}")
                elif tokens_remaining < 512:
                    logger.debug(f"{tokens_remaining:_} tokens remaining in total context size of {loaded_model.underlying_model.context_params.n_ctx}")

                if tokens_remaining < 10:
                    info_str = (
                        f"Token count near or exceeded context size: {cfr_prompt_token_len} prompt + {response_tokens} new"
                        f" >= n_ctx={loaded_model.underlying_model.context_params.n_ctx}"
                    )
                    status_holder.set("[lcp] " + info_str)
                    yield {
                        "error": info_str,
                        "done": False,
                        "status": status_holder.get(),
                    }

        # Main function body: maybe apply templating + kick off inference
        try_custom_templatoor: bool = True
        custom_templatoor_succeeded: bool = False

        for message in messages_list:
            # TODO: Update this once we have an actual format for storing image uploads
            if hasattr(message, "images"):
                try_custom_templatoor = False

        if try_custom_templatoor:
            try:
                # This branch unwraps the code within llama_cpp, so we can do our custom assistant response seed etc etc
                cfr: ChatFormatterResponse
                iter0: Iterator[JSONDict]

                templator = TemplateApplier(loaded_model.underlying_model, inference_options)
                cfr: ChatFormatterResponse = templator(messages=[m.model_dump() for m in messages_list])

                iter0: Iterator[CreateCompletionStreamResponse]
                iter0, cfr_prompt_token_len = await loaded_model.do_completion(
                    cfr,
                    inference_options,
                    status_holder,
                )

                iter1: Iterator[str] = map(normal_completion_choice0_extractor, iter0)
                iter2: AsyncIterator[str] = to_async(iter1)

                custom_templatoor_succeeded = True

            except ValueError as e:
                logger.error(f"Failed to do_completion: {e}")

                # Re-raise, because this is something that should be surfaced directly, e.g.:
                #
                # - Requested tokens exceeded context window
                #
                raise

            except jinja2.exceptions.TemplateSyntaxError as e:
                status_holder.push(f"Failed to apply custom chat template: {e}")
                logger.exception(f"Failed to apply custom chat template: {e}")

        # Otherwise, just fall back to llama-cpp-python's built-in chat formatters, end-to-end.
        if not custom_templatoor_succeeded:
            iterator_or_completion: \
                llama_cpp.CreateChatCompletionResponse | Iterator[llama_cpp.CreateChatCompletionStreamResponse]
            iterator_or_completion = await loaded_model.do_chat(
                messages=[m.model_dump() for m in messages_list],
                inference_options=inference_options,
            )

            if isinstance(iterator_or_completion, Iterator):
                iter0: Iterator[JSONDict] = iterator_or_completion
                iter1: Iterator[str] = map(chat_completion_choice0_extractor, iter0)
                iter2: AsyncIterator[str] = to_async(iter1)
            else:
                async def one_chunk_to_async() -> AsyncIterator[str]:
                    yield chat_completion_choice0_extractor(iterator_or_completion)

                iter2: AsyncIterator[str] = one_chunk_to_async()

            # Additional variables needed for later wrap-up
            cfr: ChatFormatterResponse = ChatFormatterResponse(prompt="")
            cfr_prompt_token_len: int | None = None

        iter3: AsyncIterator[JSONDict] = format_response(iter2)
        if tee_to_console:
            iter4: AsyncIterator[JSONDict] = \
                tee_to_console_output(iter3, lambda chunk: safe_get(chunk, "message", "content"))
        else:
            iter4 = iter3
        iter5: AsyncIterator[JSONDict] = update_status_and_log_info(iter4, cfr_prompt_token_len=cfr_prompt_token_len)

        status_holder.set(f"{inference_model.human_id} loaded, starting inference")

        available_ram = psutil.virtual_memory().available / (1 << 30)
        total_ram = psutil.virtual_memory().total / (1 << 30)
        logger.info(f"Available RAM (cache allocated): {available_ram:_.1f} GB / {total_ram:_.1f} total")

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
            inference_model,
            inference_options,
            status_holder,
        )

        return iter3

    async def do_chat(
            self,
            sequence_id: ChatSequenceID,
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            retrieval_context: Awaitable[PromptText | None],
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

        async def update_inference_event(
                primordial: AsyncIterator[JSONDict],
                active_inference_event: InferenceEventOrm,
        ) -> AsyncIterator[JSONDict]:
            # TODO: Calculate how many tokens are in our actual prompt
            #       Don't tokenize twice, deduplicate with the _OneModel's earlier tokenization.
            #       Or maybe it doesn't matter too much.
            prompt_tokens: int | None = None
            prompt_eval_start_time = active_inference_event.response_created_at or datetime.now(tz=timezone.utc).replace(tzinfo=None)
            prompt_eval_end_time: datetime | None = None

            response_tokens = 0
            response_eval_start_time: datetime | None = None

            async for chunk in primordial:
                yield chunk

                # If this is the first token we're picking up
                if prompt_eval_end_time is None or response_eval_start_time is None:
                    reference_time = datetime.now(tz=timezone.utc)
                    prompt_eval_end_time = reference_time.replace(tzinfo=None)
                    response_eval_start_time = reference_time

                response_tokens += 1

            # Once we're done, actually update the statistics fields
            active_inference_event.prompt_tokens = prompt_tokens
            if prompt_eval_end_time is not None and prompt_eval_start_time is not None:
                active_inference_event.prompt_eval_time = (prompt_eval_end_time - prompt_eval_start_time).total_seconds()

            active_inference_event.response_tokens = response_tokens
            if response_eval_start_time is not None:
                response_eval_duration = (datetime.now(tz=timezone.utc) - response_eval_start_time).total_seconds()
                active_inference_event.response_eval_time = response_eval_duration

            # NB Don't add this to SQLite object graph until after inference is done,
            # because the object becomes stale and will need to be merged back in.
            history_db.add(active_inference_event)

        async def prepend_prompt_text(
                primordial: AsyncIterator[JSONDict],
                cfr: ChatFormatterResponse,
        ) -> AsyncIterator[JSONDict]:
            # Return a chunk that includes the entire context-y prompt.
            # This is marked a separate packet to guard against overflows and similar.
            yield {
                "prompt_with_templating": cfr.prompt,
            }

            async for chunk in primordial:
                yield chunk

        async def append_response_chunk(
                consolidated_response: JSONDict,
                cfr: ChatFormatterResponse,
                active_inference_event: InferenceEventOrm,
        ) -> AsyncIterator[JSONDict]:
            # And now, construct the ChatSequence (which references the InferenceEvent, actually)
            try:
                active_inference_event.prompt_with_templating = cfr.prompt
                active_inference_event.response_info = consolidated_response
                active_inference_event.reason = "LlamaCppProvider.do_chat_logged"

                response_message: ChatMessageOrm | None = construct_assistant_message(
                    maybe_response_seed=inference_options.seed_assistant_response or "",
                    assistant_response=safe_get(consolidated_response, "message", "content") or "",
                    created_at=active_inference_event.response_created_at,
                    history_db=history_db,
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

                response_sequence.generated_at = active_inference_event.response_created_at
                response_sequence.generation_complete = True
                response_sequence.inference_job_id = active_inference_event.id
                if active_inference_event.response_error:
                    response_sequence.inference_error = active_inference_event.response_error

                # TODO: Investigate replacing this with plain .flush()
                history_db.commit()

                # And complete the circular reference that really should be handled in the SQLAlchemy ORM
                inference_job = history_db.merge(active_inference_event)
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

        prompt_override: PromptText | None = await retrieval_context
        if prompt_override is not None:
            status_holder.set(
                f"[lcp] {inference_model.human_id}: running inference with retrieval context of {len(prompt_override):_} chars")

            rag_message = ChatMessage(
                role="user",
                content=prompt_override,
                created_at=datetime.now(tz=timezone.utc))

            if messages_list and messages_list[-1].role == "user":
                # TODO: Is this really how we want to implement RAG? Overriding the user message?
                messages_list.pop()
                messages_list.append(rag_message)
            else:
                messages_list.append(rag_message)

        active_inference_event = InferenceEventOrm(
            model_record_id=inference_model.id,
            prompt_with_templating=None,
            response_created_at=datetime.now(tz=timezone.utc),
            response_info={},
            reason="LlamaCppProvider.do_chat_logged (in progress/exited prematurely)",
        )

        history_db.add(active_inference_event)
        history_db.commit()

        iter3: AsyncIterator[JSONDict]
        cfr, iter3 = await self._do_chat_nolog(
            messages_list,
            inference_model,
            inference_options,
            status_holder,
        )
        iter4: AsyncIterator[JSONDict] = prepend_prompt_text(iter3, cfr)
        iter5: AsyncIterator[JSONDict] = update_inference_event(iter4, active_inference_event)
        iter6: AsyncIterator[JSONDict] = consolidate_and_yield(
            iter5, content_consolidator, {},
            functools.partial(append_response_chunk, cfr=cfr, active_inference_event=active_inference_event))

        return iter6

    #  endregion
