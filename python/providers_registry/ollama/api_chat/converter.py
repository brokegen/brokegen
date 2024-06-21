import logging
from typing import AsyncIterator, AsyncGenerator

import httpx
import starlette.requests
from starlette.exceptions import HTTPException

from _util.json import safe_get, JSONDict
from _util.json_streaming import JSONStreamingResponse
from _util.typing import PromptText, TemplatedPromptText
from audit.http import AuditDB
from client.database import HistoryDB
from inference.continuation import InferenceOptions
from inference.iterators import stream_str_to_json
from inference.prompting.templating import apply_llm_template
from providers.inference_models.orm import FoundationeModelRecordOrm
from .logging import OllamaRequestContentJSON
from ..chat_rag_util import do_generate_nolog
from ..chat_routes import lookup_model

logger = logging.getLogger(__name__)


async def translate_generate_to_chat(
        primordial: AsyncIterator[JSONDict],
) -> AsyncGenerator[JSONDict, None]:
    async for chunk_json in primordial:
        chunk_json['message'] = {
            'content': safe_get(chunk_json, 'response'),
            'role': 'assistant',
        }
        del chunk_json['response']

        yield chunk_json


async def convert_chat_to_generate(
        original_request: starlette.requests.Request,
        chat_request_content: OllamaRequestContentJSON,
        inference_model: FoundationeModelRecordOrm,
        inference_options: InferenceOptions,
        requested_system_message: PromptText | None,
        prompt_override: PromptText | None,
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> tuple[TemplatedPromptText, JSONStreamingResponse]:
    model, executor_record = await lookup_model(
        chat_request_content['model'],
        history_db,
        audit_db,
    )

    model_template = (
            inference_options.override_model_template
            or safe_get(chat_request_content, 'options', 'template')
            or safe_get(model.combined_inference_parameters, 'template')
            or ''
    )
    if not model_template:
        logger.error(f"No Ollama template info for {model.human_id}, fill it in with an /api/show proxy call")
        raise HTTPException(500, "No model template available, confirm that FoundationModelRecords are complete")

    system_message = (
        # This first one is from intercepting an Ollama /api/chat request, which should take precedence.
            requested_system_message
            # Or, actually, they should simply never overlap. Only one or the other should exist.
            or inference_options.override_system_prompt
            or safe_get(chat_request_content, 'options', 'system')
            or safe_get(model.combined_inference_parameters, 'system')
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

        converted = await apply_llm_template(
            model_template,
            system_message if is_first_message else None,
            message['content'] if message['role'] == 'user' else None,
            message['content'] if message['role'] == 'assistant'
            else (inference_options.seed_assistant_response if is_last_message else None),
            is_last_message,
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
            # TODO: Figure out how/what to truncate
            existing_content = sum(map(len, templated_messages))
            logging.debug(
                f"Existing chat history is {existing_content} chars, "
                f"adding prompt_override with {len(prompt_override):_} chars:\n"
                f"{prompt_override[:280]}"
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

    for unsupported_field in ['messages', 'template', 'system', 'context']:
        if unsupported_field in generate_request_content:
            del generate_request_content[unsupported_field]

    # content-length header will no longer be correct
    modified_headers = original_request.headers.mutablecopy()
    del modified_headers['content-length']

    generate_response: httpx.Response = await do_generate_nolog(generate_request_content)
    iter0: AsyncIterator[str] = generate_response.aiter_text()
    iter1: AsyncIterator[JSONDict] = stream_str_to_json(iter0)
    iter2: AsyncIterator[JSONDict] = translate_generate_to_chat(iter1)

    # DEBUG: content-length is also still not correct, sometimes?
    # I would guess this only happens for `stream=false` requests, because otherwise how would this make sense?
    converted_response_headers = dict(generate_response.headers)
    for unsupported_field in ['content-length']:
        if unsupported_field in converted_response_headers:
            del converted_response_headers[unsupported_field]

    return generate_request_content['prompt'], JSONStreamingResponse(
        content=iter2,
        status_code=generate_response.status_code,
        headers=converted_response_headers,
    )
