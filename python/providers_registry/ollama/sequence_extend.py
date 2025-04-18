import functools
import logging
from datetime import datetime, timezone
from typing import AsyncIterator

import fastapi.routing
import sqlalchemy
import starlette.datastructures
import starlette.requests
from fastapi import Depends
from sqlalchemy import select
from starlette.responses import RedirectResponse

from _util.json import JSONDict, safe_get
from _util.json_streaming import JSONStreamingResponse
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, TemplatedPromptText
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from client.database import HistoryDB, get_db as get_history_db
from client.message import ChatMessageOrm, ChatMessage
from client.sequence import ChatSequenceOrm
from client.sequence_get import fetch_messages_for_sequence
from inference.continuation import ContinueRequest, select_continuation_model, AutonamingOptions
from inference.iterators import consolidate_and_yield, tee_to_console_output
from inference.logging import construct_new_sequence_from, construct_assistant_message
from providers.foundation_models.orm import FoundationModelRecordOrm, InferenceEventOrm
from providers.orm import ProviderLabel
from providers.registry import ProviderRegistry, InferenceOptions
from retrieval.faiss.retrieval import RetrievalLabel
from .api_chat.inject_rag import do_proxy_chat_rag
from .api_chat.logging import ollama_response_consolidator, \
    OllamaResponseContentJSON, finalize_inference_job, ollama_log_indexer
from .json import keepalive_wrapper
from .sequence_autoname import ollama_autoname_sequence

logger = logging.getLogger(__name__)


async def prepend_prompt_text(
        primordial: AsyncIterator[JSONDict],
        prompt_with_templating: TemplatedPromptText,
) -> AsyncIterator[JSONDict]:
    yield {
        "prompt_with_templating": prompt_with_templating,
    }

    async for chunk in primordial:
        yield chunk


async def do_continuation(
        messages_list: list[ChatMessage],
        original_sequence: ChatSequenceOrm,
        inference_model: FoundationModelRecordOrm,
        inference_options: InferenceOptions,
        autonaming_options: AutonamingOptions,
        retrieval_label: RetrievalLabel,
        status_holder: ServerStatusHolder,
        empty_request: starlette.requests.Request,
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> JSONStreamingResponse:
    async def append_response_chunk(
            consolidated_response: OllamaResponseContentJSON,
            prompt_with_templating: TemplatedPromptText,
    ) -> AsyncIterator[JSONDict]:
        nonlocal inference_model
        inference_model = history_db.merge(inference_model)

        inference_event = InferenceEventOrm(
            model_record_id=inference_model.id,
            prompt_with_templating=prompt_with_templating,
            reason="[ollama] ChatSequence continuation",
            response_created_at=datetime.now(tz=timezone.utc),
            response_error="[haven't received/finalized response info yet]",
        )
        finalize_inference_job(inference_event, consolidated_response)

        try:
            history_db.add(inference_event)
            history_db.commit()
        except sqlalchemy.exc.SQLAlchemyError:
            logger.exception(f"Failed to commit {inference_event=}")
            history_db.rollback()
            return

        # And now, construct the ChatSequence (which references the InferenceEvent, actually)
        try:
            response_message: ChatMessageOrm | None = construct_assistant_message(
                maybe_response_seed=inference_options.seed_assistant_response or "",
                assistant_response=ollama_log_indexer(consolidated_response),
                created_at=inference_event.response_created_at,
                history_db=history_db,
            )
            if not response_message:
                print(f"[ERROR] Failed to construct_assistant_message() from \"{ollama_log_indexer(consolidated_response)}\"")
                return

            response_sequence: ChatSequenceOrm = await construct_new_sequence_from(
                original_sequence,
                response_message.id,
                inference_event,
                history_db,
            )

            if safe_get(consolidated_response, 'done'):
                logger.warning(f"ChatSequence#{response_sequence.id} continuation received \"done\", but we still have JSON chunks to send")

        except sqlalchemy.exc.SQLAlchemyError:
            logger.exception(f"Failed to create add-on ChatSequence from {consolidated_response}")
            history_db.rollback()
            return

        except Exception:
            logger.exception(f"Failed to create add-on ChatSequence from {consolidated_response}")
            status_holder.set("Failed to create add-on ChatSequence")
            yield {
                "error": "Failed to create add-on ChatSequence",
                "done": True,
            }
            return

        # Lastly (after inference), do auto-naming, if needed
        if not response_sequence.human_desc:
            consolidated_messages = list(messages_list)
            consolidated_messages.append(ChatMessage.model_validate(response_message))

            name = await ollama_autoname_sequence(consolidated_messages, inference_model, status_holder)
            logger.info(f"Auto-generated chat title is {len(name)} chars: {name=}")
            response_sequence.human_desc = name

            history_db.add(response_sequence)
            history_db.commit()

        # Return fields that the client probably cares about
        yield {
            "new_message_id": response_sequence.current_message,
            "new_sequence_id": response_sequence.id,
            "autoname": response_sequence.human_desc,
            "done": True,
        }

    async def hide_done(
            primordial: AsyncIterator[JSONDict],
    ) -> AsyncIterator[JSONDict]:
        done_signaled: int = 0

        async for chunk_json in primordial:
            if safe_get(chunk_json, "done"):
                done_signaled += 1
                chunk_json["done"] = False

                # If we're nominally done, pretend we're not so we can add a block
                yield chunk_json
                continue

            else:
                yield chunk_json

                if done_signaled > 0:
                    logger.warning(f"ollama /api/chat: Still yielding chunks after `done=True`")

        if not done_signaled:
            logger.warning(f"ollama /api/chat: Finished streaming response without hitting `done=True`")

    async def update_status(
            primordial: AsyncIterator[JSONDict],
    ) -> AsyncIterator[JSONDict]:
        # NB We're assuming one token per chunk, which seems like the most likely implementation.
        # TODO: Double check this, and across ollama version updates, too.
        response_tokens = 0
        response_eval_start_time: datetime | None = None

        async for chunk in primordial:
            # If this is the first token we're picking up
            if response_eval_start_time is None:
                response_eval_start_time = datetime.now(tz=timezone.utc)

            response_tokens += 1
            response_eval_duration = (datetime.now(tz=timezone.utc) - response_eval_start_time).total_seconds()

            # Update `status_holder` first so any downstream iterator-processors read it.
            status_holder.set(f"{inference_model.human_id}: {response_tokens} generated in {response_eval_duration:_.3f} seconds")

            # For the most part, the upstream chunk generators are forwarded straight from ollama.
            # We don't expect any of them to have the "status" set, but check anyway.
            if "status" not in chunk:
                chunk["status"] = status_holder.get()

            yield chunk

        status_holder.set(f"[ollama] {inference_model.human_id}: done with inference")

    constructed_ollama_request_content_json = {
        "messages": messages_list,
        "model": inference_model.human_id,
    }

    prompt_with_templating: TemplatedPromptText
    proxied_response: JSONStreamingResponse
    prompt_with_templating, proxied_response = await do_proxy_chat_rag(
        empty_request,
        constructed_ollama_request_content_json,
        inference_model=inference_model,
        inference_options=inference_options,
        retrieval_label=retrieval_label,
        history_db=history_db,
        audit_db=audit_db,
        status_holder=status_holder,
        requested_system_message=None,
    )

    # Convert to JSON chunks
    iter1: AsyncIterator[JSONDict] = proxied_response._content_iterable
    iter2: AsyncIterator[JSONDict] = update_status(iter1)
    iter3: AsyncIterator[JSONDict] = tee_to_console_output(iter2, ollama_log_indexer)
    iter4: AsyncIterator[JSONDict] = prepend_prompt_text(iter3, prompt_with_templating)

    # All for the sake of consolidate + add "new_sequence_id" chunk
    iter5: AsyncIterator[JSONDict] = hide_done(iter4)
    iter6: AsyncIterator[JSONDict] = consolidate_and_yield(
        iter5, ollama_response_consolidator, {},
        functools.partial(append_response_chunk, prompt_with_templating=prompt_with_templating),
    )

    proxied_response._content_iterable = iter6
    return proxied_response


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post(
        "/sequences/{sequence_id:int}/continue",
        response_model=None,
    )
    async def sequence_continue(
            request: starlette.requests.Request,
            sequence_id: ChatSequenceID,
            params: ContinueRequest,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ) -> JSONStreamingResponse | RedirectResponse | starlette.responses.JSONResponse:
        original_sequence = history_db.execute(
            select(ChatSequenceOrm)
            .filter_by(id=sequence_id)
        ).scalar_one()

        messages_list: list[ChatMessage] = \
            fetch_messages_for_sequence(
                sequence_id, history_db, include_model_info_diffs=False, include_sequence_info=True)

        # Decide how to continue inference for this sequence
        inference_model: FoundationModelRecordOrm = \
            select_continuation_model(sequence_id, params.continuation_model_id, params.fallback_model_id, history_db)
        provider_label: ProviderLabel | None = registry.provider_label_from(inference_model)
        if provider_label is not None and provider_label.type != "ollama":
            return RedirectResponse(
                request.url_for('sequence_continue_v2', sequence_id=original_sequence.id)
                .include_query_params(parameters=params)
            )

        status_holder = ServerStatusHolder(f"[ollama] {inference_model.human_id}: starting /sequences/{sequence_id}/continue")

        # And RetrievalLabel
        retrieval_label = RetrievalLabel(
            retrieval_policy=params.retrieval_policy,
            retrieval_search_args=params.retrieval_search_args,
            preferred_embedding_model=params.preferred_embedding_model,
        )

        try:
            return await keepalive_wrapper(
                inference_model.human_id,
                do_continuation(
                    messages_list=messages_list,
                    original_sequence=original_sequence,
                    inference_model=inference_model,
                    inference_options=params,
                    autonaming_options=params,
                    retrieval_label=retrieval_label,
                    status_holder=status_holder,
                    empty_request=request,
                    history_db=history_db,
                    audit_db=audit_db,
                ),
                status_holder,
                allow_non_ollama_fields=True,
            )

        except fastapi.HTTPException as e:
            return starlette.responses.JSONResponse(
                content={
                    "model": inference_model.human_id,
                    "message": {
                        "role": "assistant",
                        "content": str(e),
                    },
                    "done": True,
                },
                status_code=e.status_code,
            )
