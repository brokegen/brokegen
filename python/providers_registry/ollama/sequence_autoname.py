from typing import AsyncIterator

import starlette.responses

from _util.json import safe_get, JSONDict
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import PromptText, TemplatedPromptText
from audit.http import get_db as get_audit_db
from client.database import get_db as get_history_db
from client.message import ChatMessage
from inference.iterators import decode_from_bytes, stream_str_to_json
from providers_registry.ollama.templating import apply_llm_template
from providers.foundation_models.orm import FoundationModelRecordOrm, InferenceReason
from .api_chat.logging import ollama_log_indexer, ollama_response_consolidator
from .api_generate import do_generate_raw_templated


async def do_autoname_sequence(
        autonaming_model: FoundationModelRecordOrm,
        inference_reason: InferenceReason,
        system_message: PromptText | None,
        user_prompt: PromptText | None,
        assistant_response: PromptText | None,
) -> PromptText:
    model_template = safe_get(autonaming_model.combined_inference_parameters, 'template')

    final_system_message = (
            system_message
            or safe_get(autonaming_model.combined_inference_parameters, 'system')
            or None
    )

    templated_query: TemplatedPromptText = await apply_llm_template(
        model_template=model_template,
        system_message=final_system_message,
        user_prompt=user_prompt,
        assistant_response=assistant_response,
        break_early_on_response=True)

    # For some (most?) templates, the assistant response "seed" is treated as its own message.
    # (Specifically, llama-3.1-8b-instruct default template appends "<|eot_id|>\n<|start_header_id|>assistant<|end_header_id|>\n".)
    #
    # To work around this, snip off any trailing text after the prompt.
    if assistant_response is not None:
        assistant_response_start_index = templated_query.rfind(assistant_response)
        if assistant_response_start_index != -1:
            templated_query = templated_query[:assistant_response_start_index + len(assistant_response)]

    response0: starlette.responses.StreamingResponse = await do_generate_raw_templated(
        request_content={
            'model': autonaming_model.human_id,
            'prompt': templated_query,
            'raw': True,
            'stream': True,
        },
        history_db=next(get_history_db()),
        audit_db=next(get_audit_db()),
        inference_reason=inference_reason,
    )

    iter0: AsyncIterator[bytes] = response0.body_iterator
    iter1: AsyncIterator[str] = decode_from_bytes(iter0)
    iter2: AsyncIterator[JSONDict] = stream_str_to_json(iter1)

    consolidated_response = {}
    async for chunk in iter2:
        consolidated_response = ollama_response_consolidator(chunk, consolidated_response)
        # TODO: We can probably check the response-so-far for a complete title, aka non-blank lines, and exit early.

    returned_title = ollama_log_indexer(consolidated_response)
    for maybe_title in returned_title.splitlines():
        stripped_title = maybe_title.strip()
        if stripped_title:
            return stripped_title

    return ""


async def ollama_autoname_sequence(
        messages_list: list[ChatMessage],
        autonaming_model: FoundationModelRecordOrm,
        status_holder: ServerStatusHolder,
) -> PromptText:
    with StatusContext(
            f"Autonaming ChatSequence with {len(messages_list)} messages => ollama {autonaming_model.human_id}",
            status_holder):
        name: str = await do_autoname_sequence(
            autonaming_model,
            inference_reason=f"[ollama] ChatSequence autoname",
            system_message=None,
            user_prompt="Summarize the provided messages, suitable as a short description for a tab title. " +
                        "Answer with that title only, do not provide additional information. Reply with exactly one title.\n\n" +
                        '\n'.join([m.content for m in messages_list]),
            assistant_response="Tab title: ",
        )

    # Only strip when both leading and trailing, otherwise we're probably just dropping half of a set.
    # TODO: Switch this to DSPy
    if len(name) > 0:
        name = name.strip()
        # Or, if there's literally only one quote at the end
        if name.count('"') == 1 and name[-1] == '"':
            name = name[:-1]
    if len(name) > 2:
        if name[0] == '"' and name[-1] == '"':
            name = name.strip('"')

    return name
