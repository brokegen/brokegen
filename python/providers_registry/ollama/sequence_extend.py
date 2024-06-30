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

from _util.json import JSONDict
from _util.json_streaming import JSONStreamingResponse
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, TemplatedPromptText
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from client.message import ChatMessageOrm, lookup_chat_message, ChatMessage
from client.sequence import ChatSequenceOrm
from client.database import HistoryDB, get_db as get_history_db
from client.sequence_add import do_extend_sequence
from client.sequence_get import fetch_messages_for_sequence
from inference.continuation import ContinueRequest, ExtendRequest, select_continuation_model, AutonamingOptions
from inference.iterators import consolidate_and_yield, tee_to_console_output
from providers.foundation_models.orm import FoundationModelRecordOrm, InferenceEventOrm
from providers.orm import ProviderLabel
from providers.registry import ProviderRegistry, InferenceOptions
from retrieval.faiss.retrieval import RetrievalLabel
from .api_chat.inject_rag import do_proxy_chat_rag
from .api_chat.logging import ollama_response_consolidator, construct_new_sequence_from, \
    OllamaResponseContentJSON, finalize_inference_job, ollama_log_indexer
from .json import keepalive_wrapper
from .sequence_autoname import autoname_sequence

logger = logging.getLogger(__name__)


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

        # Store everything we can into the InferenceEvent
        inference_event = InferenceEventOrm(
            model_record_id=inference_model.id,
            prompt_with_templating=prompt_with_templating,
            reason="ChatSequence continuation",
            response_created_at=datetime.now(tz=timezone.utc),
            response_error="[haven't received/finalized response info yet]",
        )
        finalize_inference_job(inference_event, consolidated_response)

        try:
            history_db.add(inference_event)
            history_db.commit()
        except sqlalchemy.exc.SQLAlchemyError:
            logger.exception(f"Failed to commit `prompt_with_templating` for {inference_event}")
            history_db.rollback()

        # And now, construct the ChatSequence (which references the InferenceEvent, actually)
        response_pair: tuple[ChatSequenceOrm, ChatMessageOrm] | None = None
        try:
            response_pair = await construct_new_sequence_from(
                original_sequence,
                inference_options.seed_assistant_response,
                consolidated_response,
                inference_event,
                history_db,
            )
        except sqlalchemy.exc.SQLAlchemyError:
            logger.exception(f"Failed to create add-on ChatSequence from {consolidated_response}")
            history_db.rollback()

        if response_pair is None:
            status_holder.set("Failed to construct a new ChatSequence")
            yield {
                "error": "Failed to construct a new ChatSequence",
                "done": True,
            }
            return

        # Lastly (after inference), do auto-naming
        if not response_pair[0].human_desc:
            consolidated_messages = list(messages_list)
            consolidated_messages.append(ChatMessage.model_validate(response_pair[1]))

            name = await autoname_sequence(messages_list, inference_model, status_holder)
            logger.info(f"Auto-generated chat title is {len(name)} chars: {name=}")
            response_pair[0].human_desc = name

            history_db.add(response_pair[0])
            history_db.commit()

        # Return fields that the client probably cares about
        yield {
            "new_message_id": response_pair[1].id,
            "new_sequence_id": response_pair[0].id,
            "autoname": response_pair[0].human_desc,
            "done": True,
        }

    async def hide_done(
            primordial: AsyncIterator[JSONDict],
    ) -> AsyncIterator[JSONDict]:
        done_signaled: int = 0

        async for chunk_json in primordial:
            if chunk_json["done"]:
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
        autonaming_options=autonaming_options,
        retrieval_label=retrieval_label,
        history_db=history_db,
        audit_db=audit_db,
        capture_chat_messages=False,
        status_holder=status_holder,
    )

    # Convert to JSON chunks
    iter1: AsyncIterator[JSONDict] = proxied_response._content_iterable
    iter2: AsyncIterator[JSONDict] = tee_to_console_output(iter1, ollama_log_indexer)

    # All for the sake of consolidate + add "new_sequence_id" chunk
    iter3: AsyncIterator[JSONDict] = hide_done(iter2)
    iter4: AsyncIterator[JSONDict] = consolidate_and_yield(
        iter3, ollama_response_consolidator, {},
        functools.partial(append_response_chunk, prompt_with_templating=prompt_with_templating),
    )

    proxied_response._content_iterable = iter4
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
    ) -> JSONStreamingResponse | RedirectResponse:
        original_sequence = history_db.execute(
            select(ChatSequenceOrm)
            .filter_by(id=sequence_id)
        ).scalar_one()

        messages_list: list[ChatMessage] = \
            fetch_messages_for_sequence(sequence_id, history_db, include_model_info_diffs=False,
                                        include_sequence_info=True)

        # Decide how to continue inference for this sequence
        inference_model: FoundationModelRecordOrm = \
            select_continuation_model(sequence_id, params.continuation_model_id, params.fallback_model_id, history_db)
        provider_label: ProviderLabel | None = registry.provider_label_from(inference_model)
        if provider_label is not None and provider_label.type != "ollama":
            return RedirectResponse(
                request.url_for('sequence_continue_v2', sequence_id=original_sequence.id)
                .include_query_params(parameters=params)
            )

        status_holder = ServerStatusHolder(
            f"/sequences/{sequence_id}/continue: processing on {inference_model.human_id}")

        # And RetrievalLabel
        retrieval_label = RetrievalLabel(
            retrieval_policy=params.retrieval_policy,
            retrieval_search_args=params.retrieval_search_args,
            preferred_embedding_model=params.preferred_embedding_model,
        )

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
            request,
            allow_non_ollama_fields=True,
        )

    @router_ish.post(
        "/sequences/{sequence_id:int}/extend",
        response_model=None,
    )
    async def sequence_extend(
            request: starlette.requests.Request,
            sequence_id: ChatSequenceID,
            params: ExtendRequest,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ) -> JSONStreamingResponse | RedirectResponse:
        # Manually fetch the message + model config history from our requests
        messages_list: list[ChatMessage] = \
            fetch_messages_for_sequence(sequence_id, history_db, include_model_info_diffs=False,
                                        include_sequence_info=True)

        # First, store the message that was painstakingly generated for us.
        original_sequence = history_db.execute(
            select(ChatSequenceOrm)
            .filter_by(id=sequence_id)
        ).scalar_one()

        user_sequence = ChatSequenceOrm(
            human_desc=original_sequence.human_desc,
            parent_sequence=original_sequence.id,
            generated_at=datetime.now(tz=timezone.utc),
            generation_complete=False,
        )

        maybe_message = lookup_chat_message(params.next_message, history_db)
        if maybe_message is not None:
            messages_list.append(ChatMessage.model_validate(maybe_message))
            user_sequence.current_message = maybe_message.id
            user_sequence.generation_complete = True
        else:
            new_message = ChatMessageOrm(**params.next_message.model_dump())
            history_db.add(new_message)
            history_db.commit()
            messages_list.append(ChatMessage.model_validate(new_message))
            user_sequence.current_message = new_message.id
            user_sequence.generation_complete = True

        # Mark this user response as the current up-to-date
        user_sequence.user_pinned = original_sequence.user_pinned
        original_sequence.user_pinned = False

        history_db.add(original_sequence)
        history_db.add(user_sequence)
        history_db.commit()

        # Decide how to continue inference for this sequence
        inference_model: FoundationModelRecordOrm = \
            select_continuation_model(sequence_id, params.continuation_model_id, params.fallback_model_id, history_db)
        provider_label: ProviderLabel | None = registry.provider_label_from(inference_model)
        if provider_label is not None and provider_label.type != "ollama":
            new_sequence: ChatSequenceOrm = do_extend_sequence(sequence_id, user_sequence.current_message, history_db)
            return RedirectResponse(
                request.url_for('sequence_continue_v2', sequence_id=new_sequence.id)
                .include_query_params(parameters=params)
            )

        status_holder = ServerStatusHolder(
            f"/sequences/{sequence_id}/extend: processing on {inference_model.human_id}")

        # And RetrievalLabel
        retrieval_label = RetrievalLabel(
            retrieval_policy=params.retrieval_policy,
            retrieval_search_args=params.retrieval_search_args,
            preferred_embedding_model=params.preferred_embedding_model,
        )

        return await keepalive_wrapper(
            inference_model.human_id,
            do_continuation(
                messages_list=messages_list,
                original_sequence=original_sequence if user_sequence.id is None else user_sequence,
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
            request,
            allow_non_ollama_fields=True,
        )
