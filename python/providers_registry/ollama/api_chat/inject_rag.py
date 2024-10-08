import logging
from typing import AsyncIterator

import starlette.requests

from _util.json import safe_get, JSONArray, JSONDict
from _util.json_streaming import JSONStreamingResponse
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import PromptText, TemplatedPromptText
from audit.http import AuditDB
from client.database import HistoryDB
from inference.continuation_routes import with_retrieval
from inference.iterators import decode_from_bytes, stream_str_to_json
from providers_registry.ollama.templating import apply_llm_template
from providers.foundation_models.orm import InferenceReason, FoundationModelRecordOrm
from providers.registry import InferenceOptions
from providers_registry.ollama.api_chat.converter import convert_chat_to_generate
from providers_registry.ollama.api_chat.logging import OllamaRequestContentJSON, ollama_log_indexer
from providers_registry.ollama.api_generate import do_generate_raw_templated
from retrieval.faiss.retrieval import RetrievalLabel

logger = logging.getLogger(__name__)


async def do_proxy_chat_rag(
        original_request: starlette.requests.Request,
        request_content_json: OllamaRequestContentJSON,
        inference_model: FoundationModelRecordOrm,
        inference_options: InferenceOptions,
        retrieval_label: RetrievalLabel,
        history_db: HistoryDB,
        audit_db: AuditDB,
        status_holder: ServerStatusHolder,
        requested_system_message: PromptText | None,
) -> tuple[TemplatedPromptText, JSONStreamingResponse]:
    # For now, everything we could possibly retrieve is from intercepting an Ollama /api/chat,
    # so there's no need to check for /api/generate's 'content' field.
    chat_messages: JSONArray | None = safe_get(request_content_json, 'messages')
    if not chat_messages:
        raise RuntimeError("No 'messages' provided in call to /api/chat")

    async def generate_helper_fn(
            inference_reason: InferenceReason,
            system_message: PromptText | None,
            user_prompt: PromptText | None,
            assistant_response: PromptText | None = None,
    ) -> PromptText:
        """
        TODO: Don't mix parameters, because these will be for the summary + RAG LLM selections
        """
        model_template = (
                inference_options.override_model_template
                or safe_get(request_content_json, 'options', 'template')
                or safe_get(inference_model.combined_inference_parameters, 'template')
                or ''
        )

        final_system_message = (
                system_message
                # TODO: Properly handle a not-None override, allowing us to set ""
                or inference_options.override_system_prompt
                or safe_get(request_content_json, 'options', 'system')
                or safe_get(inference_options.combined_inference_parameters, 'system')
                or None
        )

        templated_query = await apply_llm_template(
            model_template=model_template,
            system_message=final_system_message,
            user_prompt=user_prompt,
            assistant_response=assistant_response,
            break_early_on_response=True)

        response0 = await do_generate_raw_templated(
            request_content={
                'model': request_content_json['model'],
                'prompt': templated_query,
                'raw': False,
                'stream': False,
            },
            history_db=history_db,
            audit_db=audit_db,
            inference_reason=inference_reason,
        )

        iter0: AsyncIterator[bytes] = response0.body_iterator
        iter1: AsyncIterator[str] = decode_from_bytes(iter0)
        iter2: AsyncIterator[JSONDict] = stream_str_to_json(iter1)

        response0_json = await anext(iter2)
        return ollama_log_indexer(response0_json)

    prompt_override: PromptText | None = await with_retrieval(
        retrieval_label=retrieval_label,
        messages_list=chat_messages,
        generate_helper_fn=generate_helper_fn,
        status_holder=status_holder,
    )

    status_desc = f"[ollama] {safe_get(request_content_json, 'model')}: forwarding one message to /api/generate"
    if len(chat_messages) > 1:
        status_desc = f"[ollama] {safe_get(request_content_json, 'model')}: forwarding {len(chat_messages)} messages to /api/generate"
    if prompt_override is not None:
        status_desc += f" with retrieval context of {len(prompt_override):_} chars"

    with StatusContext(status_desc, status_holder):
        prompt_with_templating: TemplatedPromptText
        ollama_response: JSONStreamingResponse
        prompt_with_templating, ollama_response = await convert_chat_to_generate(
            original_request=original_request,
            chat_request_content=request_content_json,
            inference_model=inference_model,
            inference_options=inference_options,
            requested_system_message=requested_system_message,
            prompt_override=prompt_override,
        )

    return prompt_with_templating, ollama_response
