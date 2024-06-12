import logging
from collections.abc import AsyncIterable
from datetime import datetime, timezone

import sqlalchemy
import sqlalchemy.exc
import starlette.datastructures
import starlette.requests

from _util.json import safe_get, JSONArray
from _util.json_streaming import JSONStreamingResponse, tee_stream_to_log_and_callback, consolidate_stream_to_json
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import PromptText
from audit.http import AuditDB
from client.database import ChatMessageOrm, ChatSequence
from inference.prompting.templating import apply_llm_template
from providers.inference_models.database import HistoryDB
from providers.inference_models.orm import InferenceEventOrm, InferenceReason
from providers_ollama.api_chat.converter import convert_chat_to_generate
from providers_ollama.api_chat.intercept import do_capture_chat_messages
from providers_ollama.chat_rag_util import finalize_inference_job, do_generate_raw_templated
from providers_ollama.chat_routes import lookup_model_offline
from providers_ollama.json import OllamaRequestContentJSON, OllamaResponseContentJSON, \
    consolidate_stream
from retrieval.faiss.knowledge import get_knowledge
from retrieval.faiss.retrieval import RetrievalPolicy, RetrievalLabel, SimpleRetrievalPolicy, \
    SummarizingRetrievalPolicy

logger = logging.getLogger(__name__)


async def do_proxy_chat_rag(
        original_request: starlette.requests.Request,
        request_content_json: OllamaRequestContentJSON,
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
        model, executor_record = await lookup_model_offline(
            request_content_json['model'],
            history_db,
        )

        model_template = (
                safe_get(request_content_json, 'options', 'template')
                or safe_get(model.combined_inference_parameters, 'template')
                or ''
        )

        final_system_message = (
                system_message
                or safe_get(request_content_json, 'options', 'system')
                or safe_get(model.combined_inference_parameters, 'system')
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
            requested_system_message=requested_system_message,
            prompt_override=prompt_override,
            history_db=history_db,
            audit_db=audit_db,
        )

    async def wrap_response(
            upstream_response: JSONStreamingResponse,
            log_output: bool = True,
    ) -> JSONStreamingResponse:
        if not log_output:
            return upstream_response

        async def consolidate_wrapper(
                primordial: AsyncIterable[OllamaResponseContentJSON],
        ) -> OllamaResponseContentJSON:
            consolidated_response = await consolidate_stream(primordial)

            if capture_chat_response:
                model, executor_record = await lookup_model_offline(
                    consolidated_response['model'],
                    history_db,
                )

                # Construct InferenceEvent
                new_ie = InferenceEventOrm(
                    model_record_id=model.id,
                    reason="chat sequence",
                )
                finalize_inference_job(new_ie, consolidated_response)

                try:
                    history_db.add(new_ie)
                    history_db.commit()
                except sqlalchemy.exc.SQLAlchemyError:
                    logger.exception(f"Failed to commit intercepted inference event for {new_ie}")
                    history_db.rollback()

                # And a ChatMessage
                response_in = ChatMessageOrm(
                    role="assistant",
                    content=safe_get(consolidated_response, "response")
                            or safe_get(consolidated_response, "message", "content"),
                    created_at=datetime.fromisoformat(safe_get(consolidated_response, "created_at"))
                               or datetime.now(tz=timezone.utc),
                )
                if response_in.content:
                    history_db.add(response_in)
                    history_db.commit()

                # Update ChatSequences
                if response_in.content and captured_sequence is not None:
                    parent_sequence = history_db.merge(captured_sequence)

                    new_sequence = ChatSequence(
                        human_desc=parent_sequence.human_desc,
                        user_pinned=parent_sequence.user_pinned,
                        current_message=response_in.id,
                        parent_sequence=parent_sequence.id,
                        generated_at=datetime.now(tz=timezone.utc),
                        generation_complete=safe_get(consolidated_response, 'done'),
                        inference_job_id=new_ie.id,
                    )

                    parent_sequence.user_pinned = False

                    try:
                        history_db.add(parent_sequence)
                        history_db.add(new_sequence)
                        history_db.commit()
                    except sqlalchemy.exc.SQLAlchemyError:
                        logger.exception(f"Failed to create add-on ChatSequence {new_sequence}")
                        history_db.rollback()

            return consolidated_response

        if log_output:
            upstream_response._content_iterable = tee_stream_to_log_and_callback(
                upstream_response._content_iterable,
                consolidate_wrapper,
            )
            return upstream_response

    if status_holder is not None:
        status_holder.set(f"Running Ollama response")

    return await wrap_response(ollama_response)
