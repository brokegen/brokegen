import json
import logging
from typing import AsyncIterator, AsyncGenerator

import httpx
import orjson
import starlette.requests
from starlette.exceptions import HTTPException

from _util.json import safe_get, JSONDict
from _util.json_streaming import JSONStreamingResponse, NDJSONStreamingResponse
from _util.typing import PromptText, TemplatedPromptText
from inference.iterators import stream_str_to_json
from providers_registry.ollama.templating import apply_llm_template
from providers.foundation_models.orm import FoundationModelRecordOrm
from providers.registry import InferenceOptions
from .logging import OllamaRequestContentJSON
from ..api_generate import do_generate_nolog

logger = logging.getLogger(__name__)


async def translate_generate_to_chat(
        primordial: AsyncIterator[JSONDict],
) -> AsyncGenerator[JSONDict, None]:
    async for chunk_json in primordial:
        chunk_json['message'] = {
            'content': safe_get(chunk_json, 'response'),
            'role': 'assistant',
        }
        # TODO: This fails in error cases, but we need to repro/debug those.
        if 'response' in chunk_json:
            del chunk_json['response']

        yield chunk_json


async def convert_chat_to_generate(
        original_request: starlette.requests.Request,
        chat_request_content: OllamaRequestContentJSON,
        inference_model: FoundationModelRecordOrm,
        inference_options: InferenceOptions,
        requested_system_message: PromptText | None,
        prompt_override: PromptText | None,
) -> tuple[TemplatedPromptText, JSONStreamingResponse]:
    used_assistant_response_seed: bool = False

    model_template = (
            inference_options.override_model_template
            or safe_get(chat_request_content, 'options', 'template')
            or safe_get(inference_model.combined_inference_parameters, 'template')
            or ''
    )
    if not model_template:
        logger.error(f"No ollama template info for {inference_model}, call /api/show to populate it")
        raise HTTPException(500, "No model template available, confirm that FoundationModelRecords are complete")

    intercepted_ollama_system_message: PromptText | None = None
    for message in chat_request_content['messages']:
        # TODO: Standardize/deduplicate attributes vs properties or whatever
        if safe_get(message, "role") == 'system':
            if intercepted_ollama_system_message is None:
                intercepted_ollama_system_message = message["content"]
            else:
                # This should never happen, but append further system messages to make a big system message.
                intercepted_ollama_system_message += "\n\n"
                intercepted_ollama_system_message += message["content"]

        elif hasattr(message, "role") and message.role == "system":
            if intercepted_ollama_system_message is None:
                intercepted_ollama_system_message = message.content
            else:
                # This should never happen, but append further system messages to make a big system message.
                intercepted_ollama_system_message += "\n\n"
                intercepted_ollama_system_message += message.content

    system_message = (
            # This first one is from intercepting an Ollama /api/chat request, which should take precedence.
            requested_system_message
            # Or, actually, they should simply never overlap. Only one or the other should exist.
            # TODO: Properly handle a not-None override, allowing us to set ""
            or inference_options.override_system_prompt
            or intercepted_ollama_system_message
            or safe_get(chat_request_content, 'options', 'system')
            or safe_get(inference_model.combined_inference_parameters, 'system')
            or ''
    )

    ollama_chat_messages = chat_request_content['messages']
    templated_messages: list[TemplatedPromptText] = []

    # TODO: Figure out what to do with request that overflows context
    #
    # TODO: Due to how Ollama templating is implemented, we basically need to bundle user/assistant requests together.
    #       Rather than doing this, just expect the user to have overridden the default templates, for now.
    #       Otherwise, we can check what happens with a null-every string message vs a non-null-assistant message.
    # TODO: Are chat models even trained on multi-turn conversation?
    for count, message in enumerate(ollama_chat_messages):
        is_first_message = count == 0
        is_last_message = (
                count == len(ollama_chat_messages) - 1
                and prompt_override is None
        )

        user_prompt_str: PromptText | None = None
        if hasattr(message, "role") and message.role == "user":
            user_prompt_str = message.content
        elif safe_get(message, "role") == "user":
            user_prompt_str = safe_get(message, "content")

        assistant_response: PromptText | None = None
        if hasattr(message, "role") and message.role == "assistant":
            assistant_response = message.content
        elif safe_get(message, "role") == "assistant":
            assistant_response = safe_get(message, "content")
        elif is_last_message:
            assistant_response = inference_options.seed_assistant_response
            used_assistant_response_seed = True

        converted = await apply_llm_template(
            model_template,
            system_message if is_first_message else None,
            user_prompt_str,
            assistant_response,
            is_last_message and used_assistant_response_seed,
        )
        templated_messages.append(converted)

    # NB The "last" message might still be an assistant response, in which case we append the message now.
    if not used_assistant_response_seed:
        converted = await apply_llm_template(
            model_template,
            None,
            None,
            inference_options.seed_assistant_response,
            True,
        )
        templated_messages.append(converted)

    if prompt_override is not None:
        # If we only have one message, then override differently
        if len(ollama_chat_messages) == 0:
            templated_messages = [await apply_llm_template(
                model_template,
                system_message,
                prompt_override,
                inference_options.seed_assistant_response,
                break_early_on_response=True,
            )]
        else:
            existing_content_len = sum(map(len, templated_messages))
            max_print_len = 280
            logging.debug(
                f"Existing chat history is {existing_content_len:_} chars, "
                f"adding prompt_override with {len(prompt_override):_} chars ({max_print_len=:_}):\n"
                f"{prompt_override[:max_print_len]}"
            )

            templated_messages.append(await apply_llm_template(
                model_template,
                '',
                prompt_override,
                '',
                break_early_on_response=True,
            ))

    generate_request_content = dict(chat_request_content)
    generate_request_content['prompt'] = '\n'.join(templated_messages)
    generate_request_content['raw'] = True
    if inference_options.inference_options:
        try:
            generate_request_content['options'] = orjson.loads(inference_options.inference_options)
            logger.debug(f"[ollama] /api/generate using provided inference options:\n{json.dumps(generate_request_content['options'], indent=2)}")

        except ValueError:
            logger.error(f"[ollama] /api/generate ignoring provided inference options (failed to parse): {inference_options.inference_options}")

    for unsupported_field in ['messages', 'template', 'system', 'context']:
        if unsupported_field in generate_request_content:
            del generate_request_content[unsupported_field]

    # content-length header will no longer be correct
    modified_headers = original_request.headers.mutablecopy()
    del modified_headers['content-length']

    generate_response: httpx.Response = await do_generate_nolog(generate_request_content)
    iter0: AsyncIterator[str] = generate_response.aiter_text()
    iter1: AsyncIterator[JSONDict] = stream_str_to_json(iter0)
    iter3: AsyncIterator[JSONDict] = translate_generate_to_chat(iter1)

    # DEBUG: content-length is also still not correct, sometimes?
    # I would guess this only happens for `stream=false` requests, because otherwise how would this make sense?
    converted_response_headers = dict(generate_response.headers)
    for unsupported_field in ['content-length']:
        if unsupported_field in converted_response_headers:
            del converted_response_headers[unsupported_field]

    return generate_request_content['prompt'], NDJSONStreamingResponse(
        content=iter3,
        status_code=generate_response.status_code,
        headers=converted_response_headers,
    )
