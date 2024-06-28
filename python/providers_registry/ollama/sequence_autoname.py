from typing import AsyncIterator

import starlette.responses

from _util.json import safe_get, JSONDict
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import PromptText
from audit.http import get_db as get_audit_db
from client.message import ChatMessage
from client.database import get_db as get_history_db
from inference.iterators import decode_from_bytes, stream_str_to_json
from inference.prompting.templating import apply_llm_template
from providers.inference_models.orm import FoundationModelRecordOrm, InferenceReason
from .api_chat.logging import ollama_log_indexer
from .api_generate import do_generate_raw_templated


async def do_autoname_sequence(
        inference_model: FoundationModelRecordOrm,
        inference_reason: InferenceReason,
        system_message: PromptText | None,
        user_prompt: PromptText | None,
        assistant_response: PromptText | None = None,
) -> PromptText:
    model_template = safe_get(inference_model.combined_inference_parameters, 'template')

    final_system_message = (
            system_message
            or safe_get(inference_model.combined_inference_parameters, 'system')
            or None
    )

    templated_query = await apply_llm_template(
        model_template=model_template,
        system_message=final_system_message,
        user_prompt=user_prompt,
        assistant_response=assistant_response,
        break_early_on_response=True)

    response0: starlette.responses.StreamingResponse = await do_generate_raw_templated(
        request_content={
            'model': inference_model.human_id,
            'prompt': templated_query,
            'raw': False,
            'stream': False,
        },
        history_db=next(get_history_db()),
        audit_db=next(get_audit_db()),
        inference_reason=inference_reason,
    )

    iter0: AsyncIterator[bytes] = response0.body_iterator
    iter1: AsyncIterator[str] = decode_from_bytes(iter0)
    iter2: AsyncIterator[JSONDict] = stream_str_to_json(iter1)

    response0_json = await anext(iter2)
    return ollama_log_indexer(response0_json)


async def autoname_sequence(
        messages_list: list[ChatMessage],
        inference_model: FoundationModelRecordOrm,
        status_holder: ServerStatusHolder,
) -> PromptText:
    with StatusContext(
            f"Autonaming ChatSequence with {len(messages_list)} messages => ollama {inference_model.human_id}",
            status_holder):
        name: str = await do_autoname_sequence(
            inference_model,
            inference_reason=f"ChatSequence autoname",
            # NB This only works as a system message on models that respect that.
            #    So, append it to both.
            system_message="You are a concise summarizer, seizing on easily identifiable + distinguishing factors of the text.",
            user_prompt="Provide a summary of the provided text, suitable as a short description for a tab title. " +
                        "Answer with that title only, do not provide additional information. Reply with at most one sentence.\n\n" +
                        '\n'.join([m.content for m in messages_list]),
            assistant_response="Tab title: "
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