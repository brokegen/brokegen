import functools
import logging
from datetime import datetime, timezone
from typing import AsyncIterator

import fastapi.routing
import orjson
import sqlalchemy
import starlette.datastructures
import starlette.requests
from fastapi import Depends
from sqlalchemy import select
from starlette.responses import RedirectResponse

from _util.json import safe_get, JSONDict
from _util.json_streaming import JSONStreamingResponse
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import ChatSequenceID, PromptText, TemplatedPromptText
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from client.chat_message import ChatMessageOrm, lookup_chat_message, ChatMessage
from client.chat_sequence import ChatSequence
from client.database import HistoryDB, get_db as get_history_db
from client.sequence_add import do_extend_sequence
from client.sequence_get import fetch_messages_for_sequence
from inference.continuation import ContinueRequest, ExtendRequest, select_continuation_model, InferenceOptions, \
    AutonamingOptions
from inference.iterators import consolidate_and_yield, tee_to_console_output
from inference.prompting.templating import apply_llm_template
from providers.inference_models.orm import FoundationModelRecordOrm, InferenceEventOrm, InferenceReason
from providers.orm import ProviderLabel
from providers.registry import ProviderRegistry
from providers_registry.ollama.api_chat.inject_rag import do_proxy_chat_rag
from providers_registry.ollama.api_chat.logging import ollama_response_consolidator, construct_new_sequence_from, \
    OllamaResponseContentJSON, finalize_inference_job, ollama_log_indexer
from providers_registry.ollama.chat_rag_util import do_generate_raw_templated
from providers_registry.ollama.json import keepalive_wrapper
from retrieval.faiss.retrieval import RetrievalLabel

logger = logging.getLogger(__name__)


async def ollama_generate_helper_fn(
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

    response0 = await do_generate_raw_templated(
        request_content={
            'model': inference_model.human_id,
            'prompt': templated_query,
            'raw': False,
            'stream': False,
        },
        request_headers=starlette.datastructures.Headers(),
        request_cookies=None,
        history_db=next(get_history_db()),
        audit_db=next(get_audit_db()),
        inference_reason=inference_reason,
    )

    content_chunks = []
    async for chunk in response0.body_iterator:
        content_chunks.append(chunk)

    response0_json = orjson.loads(b''.join(content_chunks))
    return response0_json['response']


async def autoname_sequence(
        messages_list: list[ChatMessage],
        inference_model: FoundationModelRecordOrm,
        status_holder: ServerStatusHolder,
) -> PromptText:
    with StatusContext("summarizing prompt as tab name", status_holder):
        name: str = await ollama_generate_helper_fn(
            inference_model,
            inference_reason="ChatSequence.human_desc",
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


async def do_continuation(
        messages_list: list[ChatMessage],
        original_sequence: ChatSequence,
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
        response_sequence: ChatSequence | None = None
        try:
            response_sequence = await construct_new_sequence_from(
                original_sequence,
                inference_options.seed_assistant_response,
                consolidated_response,
                inference_event,
                history_db,
            )
        except sqlalchemy.exc.SQLAlchemyError:
            logger.exception(f"Failed to create add-on ChatSequence {response_sequence}")
            history_db.rollback()

        if response_sequence is None:
            status_holder.set("Failed to construct a new ChatSequence")
            yield {
                "error": "Failed to construct a new ChatSequence",
                "done": True,
            }
            return

        # Lastly (after inference), do auto-naming
        if response_sequence is not None and not response_sequence.human_desc:
            name = await autoname_sequence(messages_list, inference_model, status_holder)
            logger.info(f"Auto-generated chat title is {len(name)} chars: {name=}")
            response_sequence.human_desc = name

            history_db.add(response_sequence)
            history_db.commit()

        yield {
            "new_sequence_id": response_sequence.id,
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
        "messages": [m.model_dump() for m in messages_list],
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
            select(ChatSequence)
            .filter_by(id=sequence_id)
        ).scalar_one()

        messages_list: list[ChatMessage] = \
            fetch_messages_for_sequence(sequence_id, history_db, include_model_info_diffs=False)

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
            fetch_messages_for_sequence(sequence_id, history_db, include_model_info_diffs=False)

        # First, store the message that was painstakingly generated for us.
        original_sequence = history_db.execute(
            select(ChatSequence)
            .filter_by(id=sequence_id)
        ).scalar_one()

        user_sequence = ChatSequence(
            human_desc=original_sequence.human_desc,
            parent_sequence=original_sequence.id,
            generated_at=datetime.now(tz=timezone.utc),
            generation_complete=False,
        )

        maybe_message = lookup_chat_message(params.next_message, history_db)
        if maybe_message is not None:
            messages_list.append(ChatMessage.from_orm(maybe_message))
            user_sequence.current_message = maybe_message.id
            user_sequence.generation_complete = True
        else:
            new_message = ChatMessageOrm(**params.next_message.model_dump())
            history_db.add(new_message)
            history_db.commit()
            messages_list.append(ChatMessage.from_orm(new_message))
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
            new_sequence: ChatSequence = do_extend_sequence(sequence_id, user_sequence.current_message, history_db)
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
