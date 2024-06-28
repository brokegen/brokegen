import logging
from typing import AsyncIterator

import starlette.datastructures
import starlette.requests

from _util.json import safe_get, JSONArray, JSONDict
from _util.json_streaming import JSONStreamingResponse
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import PromptText, TemplatedPromptText
from audit.http import AuditDB
from client.chat_sequence import ChatSequenceOrm
from client.database import HistoryDB
from inference.continuation import AutonamingOptions
from providers.registry import InferenceOptions
from inference.iterators import decode_from_bytes, stream_str_to_json
from inference.prompting.templating import apply_llm_template
from providers.inference_models.orm import InferenceReason, FoundationModelRecordOrm
from providers_registry.ollama.api_chat.converter import convert_chat_to_generate
from providers_registry.ollama.api_chat.intercept import do_capture_chat_messages
from providers_registry.ollama.api_chat.logging import OllamaRequestContentJSON, ollama_log_indexer
from providers_registry.ollama.api_generate import do_generate_raw_templated
from retrieval.faiss.knowledge import get_knowledge
from retrieval.faiss.retrieval import RetrievalPolicy, RetrievalLabel, SimpleRetrievalPolicy, \
    SummarizingRetrievalPolicy

logger = logging.getLogger(__name__)


async def do_proxy_chat_rag(
        original_request: starlette.requests.Request,
        request_content_json: OllamaRequestContentJSON,
        inference_model: FoundationModelRecordOrm,
        inference_options: InferenceOptions,
        autonaming_options: AutonamingOptions,
        retrieval_label: RetrievalLabel,
        history_db: HistoryDB,
        audit_db: AuditDB,
        capture_chat_messages: bool = True,
        capture_chat_response: bool = False,
        status_holder: ServerStatusHolder | None = None,
) -> tuple[TemplatedPromptText, JSONStreamingResponse]:
    # For now, everything we could possibly retrieve is from intercepting an Ollama /api/chat,
    # so there's no need to check for /api/generate's 'content' field.
    chat_messages: JSONArray | None = safe_get(request_content_json, 'messages')
    if not chat_messages:
        raise RuntimeError("No 'messages' provided in call to /api/chat")

    # Assume that these are messages from a third-party client, and try to feed them into the history database.
    captured_sequence: ChatSequenceOrm | None = None
    requested_system_message: PromptText | None = None
    if capture_chat_messages:
        captured_sequence, requested_system_message = do_capture_chat_messages(chat_messages, history_db)

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

    prompt_override: PromptText | None = None
    with StatusContext(f"Retrieving documents with {retrieval_label=}", status_holder):
        real_retrieval_policy: RetrievalPolicy | None = None

        if retrieval_label.retrieval_policy == "skip":
            real_retrieval_policy = None
        elif retrieval_label.retrieval_policy == "simple":
            real_retrieval_policy = SimpleRetrievalPolicy(get_knowledge())
        elif retrieval_label.retrieval_policy == "summarizing":
            init_kwargs = {
                "knowledge": get_knowledge(),
            }
            if retrieval_label.retrieval_search_args is not None:
                init_kwargs["search_args_json"] = retrieval_label.retrieval_search_args

            real_retrieval_policy = SummarizingRetrievalPolicy(**init_kwargs)

        if real_retrieval_policy is not None:
            if retrieval_label.preferred_embedding_model is not None:
                logger.warning(f"Ignoring requested embedding model, since we don't support overrides")

            prompt_override = await real_retrieval_policy.parse_chat_history(
                chat_messages, generate_helper_fn, status_holder,
            )

    status_desc = f"Forwarding ChatMessage to ollama /api/generate {safe_get(request_content_json, 'model')}"
    if len(chat_messages) > 1:
        status_desc = f"Forwarding {len(chat_messages)} messages to ollama /api/generate {safe_get(request_content_json, 'model')}"
    if prompt_override is not None:
        status_desc += f" (with retrieval context of {len(prompt_override):_} chars)"

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
            history_db=history_db,
            audit_db=audit_db,
        )

    return prompt_with_templating, ollama_response
