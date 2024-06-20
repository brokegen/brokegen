import logging
from datetime import datetime, timezone
from typing import AsyncIterator

import sqlalchemy
import sqlalchemy.exc
import starlette.datastructures
import starlette.requests

from _util.json import safe_get, JSONArray, JSONDict
from _util.json_streaming import JSONStreamingResponse, consolidate_stream_to_json
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import PromptText
from audit.http import AuditDB
from client.chat_message import ChatMessageOrm
from client.chat_sequence import ChatSequence
from inference.continuation import InferenceOptions, AutonamingOptions
from inference.iterators import tee_to_console_output, stream_bytes_to_json, consolidate_and_call, dump_to_bytes
from inference.prompting.templating import apply_llm_template
from client.database import HistoryDB
from providers.inference_models.orm import InferenceEventOrm, InferenceReason, FoundationeModelRecordOrm
from providers_registry.ollama.api_chat.converter import convert_chat_to_generate
from providers_registry.ollama.api_chat.intercept import do_capture_chat_messages
from providers_registry.ollama.api_chat.logging import ollama_log_indexer, ollama_response_consolidator, \
    finalize_inference_job, OllamaRequestContentJSON, OllamaResponseContentJSON, inference_event_logger, \
    construct_new_sequence_from
from providers_registry.ollama.chat_rag_util import do_generate_raw_templated
from providers_registry.ollama.chat_routes import lookup_model_offline
from retrieval.faiss.knowledge import get_knowledge
from retrieval.faiss.retrieval import RetrievalPolicy, RetrievalLabel, SimpleRetrievalPolicy, \
    SummarizingRetrievalPolicy

logger = logging.getLogger(__name__)


async def do_proxy_chat_rag(
        original_request: starlette.requests.Request,
        request_content_json: OllamaRequestContentJSON,
        inference_model: FoundationeModelRecordOrm,
        inference_options: InferenceOptions,
        autonaming_options: AutonamingOptions,
        retrieval_label: RetrievalLabel,
        history_db: HistoryDB,
        audit_db: AuditDB,
        capture_chat_messages: bool = True,
        capture_chat_response: bool = False,
        status_holder: ServerStatusHolder | None = None,
) -> JSONStreamingResponse:
    # For now, everything we could possibly retrieve is from intercepting an Ollama /api/chat,
    # so there's no need to check for /api/generate's 'content' field.
    chat_messages: JSONArray | None = safe_get(request_content_json, 'messages')
    if not chat_messages:
        raise RuntimeError("No 'messages' provided in call to /api/chat")

    # Assume that these are messages from a third-party client, and try to feed them into the history database.
    captured_sequence: ChatSequence | None = None
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
            request_headers=starlette.datastructures.Headers(),
            request_cookies=None,
            history_db=history_db,
            audit_db=audit_db,
            inference_reason=inference_reason,
        )

        response0_json = await consolidate_stream_to_json(response0.body_iterator)
        return response0_json['response']

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
        ollama_response = await convert_chat_to_generate(
            original_request=original_request,
            chat_request_content=request_content_json,
            inference_model=inference_model,
            inference_options=inference_options,
            requested_system_message=requested_system_message,
            prompt_override=prompt_override,
            history_db=history_db,
            audit_db=audit_db,
        )

    # TODO: Split into inference_event_logger and construct_new_sequence_from
    async def consolidate_wrapper(
            consolidated_response: OllamaResponseContentJSON,
    ) -> None:
        if not capture_chat_response:
            return

        _: InferenceEventOrm = \
            await inference_event_logger(consolidated_response, inference_model, history_db)

    if status_holder is not None:
        status_holder.set(f"Running Ollama response")

    iter0: AsyncIterator[bytes] = ollama_response._content_iterable
    iter1: AsyncIterator[JSONDict] = stream_bytes_to_json(iter0)
    iter2: AsyncIterator[JSONDict] = tee_to_console_output(iter1, ollama_log_indexer)
    iter3: AsyncIterator[JSONDict] = consolidate_and_call(
        iter2, ollama_response_consolidator, {},
        consolidate_wrapper,
    )
    iter4: AsyncIterator[bytes] = dump_to_bytes(iter3)

    ollama_response._content_iterable = iter4
    return ollama_response
