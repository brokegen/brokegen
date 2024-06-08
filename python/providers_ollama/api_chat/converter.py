import logging
from typing import AsyncIterable

import httpx
import orjson
import starlette.requests
from starlette.exceptions import HTTPException

from _util.json import safe_get
from _util.json_streaming import JSONStreamingResponse
from _util.typing import PromptText, TemplatedPromptText
from audit.http import AuditDB
from inference.prompting.templating import apply_llm_template
from providers.inference_models.database import HistoryDB
from providers_ollama.chat_rag_util import do_generate_raw_templated
from providers_ollama.chat_routes import lookup_model
from providers_ollama.json import OllamaRequestContentJSON

logger = logging.getLogger(__name__)


async def convert_chat_to_generate(
        original_request: starlette.requests.Request,
        chat_request_content: OllamaRequestContentJSON,
        requested_system_message: PromptText | None,
        prompt_override: PromptText | None,
        history_db: HistoryDB,
        audit_db: AuditDB,
):
    model, executor_record = await lookup_model(
        chat_request_content['model'],
        history_db,
        audit_db,
    )

    model_template = (
            safe_get(chat_request_content, 'options', 'template')
            or safe_get(model.combined_inference_parameters, 'template')
            or ''
    )
    if not model_template:
        logger.error(f"No Ollama template info for {model.human_id}, fill it in with an /api/show proxy call")
        raise HTTPException(500, "No model template available, confirm that InferenceModelRecords are complete")

    system_message = (
            requested_system_message
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
            message['content'] if message['role'] == 'assistant' else None,
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
                '',
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

    generate_response = await do_generate_raw_templated(
        generate_request_content,
        modified_headers,
        httpx.Cookies(original_request.cookies),
        history_db,
        audit_db,
        inference_reason="ollama: /chat to /generate raw",
    )

    async def translate_generate_to_chat(
            primordial: AsyncIterable[str | bytes],
    ) -> AsyncIterable[bytes]:
        """
        Technically, this would be easier as a simple callback,
        rather than constructing a duplicate StreamingResponse. Whatever.

        TODO: How to deal with ndjson chunks that are split across chunks
        """
        async for chunk0 in primordial:
            chunk0_json = orjson.loads(chunk0)

            chunk1 = dict(chunk0_json)
            del chunk1['response']
            chunk1['message'] = {
                'content': chunk0_json['response'],
                'role': 'assistant',
            }

            yield orjson.dumps(chunk1)

            # TODO: Make everything upstream/downstream handle this well, particularly logging
            if await original_request.is_disconnected() and not chunk1['done']:
                logger.warning(f"Detected client disconnection! Ignoring.")

    # DEBUG: content-length is also still not correct, sometimes?
    # I would guess this only happens for `stream=false` requests, because otherwise how would this make sense?
    converted_response_headers = dict(generate_response.headers)
    for unsupported_field in ['content-length']:
        if unsupported_field in converted_response_headers:
            del converted_response_headers[unsupported_field]

    return JSONStreamingResponse(
        content=translate_generate_to_chat(generate_response.body_iterator),
        status_code=generate_response.status_code,
        headers=converted_response_headers,
        background=generate_response.background,
    )