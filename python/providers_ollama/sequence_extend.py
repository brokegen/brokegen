import logging
from datetime import datetime, timezone

import fastapi.routing
import orjson
import starlette.datastructures
import starlette.requests
from fastapi import Depends
from sqlalchemy import select

from _util.json import safe_get
from _util.json_streaming import JSONStreamingResponse
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import ChatSequenceID, PromptText
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from client.database import ChatMessageOrm, ChatSequence, lookup_chat_message, ChatMessage
from client.sequence_get import do_get_sequence
from inference.continuation import ContinueRequest, ExtendRequest, select_continuation_model
from retrieval.embeddings.retrieval import RetrievalLabel
from inference.prompting.templating import apply_llm_template
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm, InferenceEventOrm, InferenceReason
from providers_ollama.api_chat.inject_rag import do_proxy_chat_rag
from providers_ollama.chat_rag_util import finalize_inference_job, do_generate_raw_templated
from providers_ollama.json import consolidate_stream_sync, keepalive_wrapper

logger = logging.getLogger(__name__)


async def ollama_generate_helper_fn(
        inference_model: InferenceModelRecordOrm,
        history_db: HistoryDB,
        audit_db: AuditDB,
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
        history_db=history_db,
        audit_db=audit_db,
        inference_reason=inference_reason,
    )

    content_chunks = []
    async for chunk in response0.body_iterator:
        content_chunks.append(chunk)

    response0_json = orjson.loads(b''.join(content_chunks))
    return response0_json['response']


async def do_continuation(
        messages_list: list[ChatMessage],
        original_sequence: ChatSequence,
        inference_model: InferenceModelRecordOrm,
        retrieval_label: RetrievalLabel,
        status_holder: ServerStatusHolder,
        empty_request: starlette.requests.Request,
        history_db: HistoryDB,
        audit_db: AuditDB,
):
    constructed_ollama_request_content_json = {
        "messages": [m.model_dump() for m in messages_list],
        "model": inference_model.human_id,
    }

    # Wrap the output in a… something that appends new ChatSequence information
    response_sequence = ChatSequence(
        human_desc=original_sequence.human_desc,
        parent_sequence=original_sequence.id,
    )

    if not original_sequence.human_desc:
        with StatusContext("summarizing prompt as tab name", status_holder):
            machine_desc: str = await ollama_generate_helper_fn(
                inference_model,
                history_db,
                audit_db,
                inference_reason="ChatSequence.human_desc",
                # NB This only works as a system message on models that respect that.
                #    So, append it to both.
                system_message="You are a concise summarizer, seizing on easily identifiable + distinguishing factors of the text.",
                user_prompt="Provide a summary of the provided text in a few words, suitable as a short description for a tab title." +
                            "Answer with that title only.\n\n" +
                            '\n'.join([m.content for m in messages_list]),
                assistant_response="Tab title: "
            )

        # Only strip when both leading and trailing, otherwise we're probably just dropping half of a set.
        if len(machine_desc) > 0:
            machine_desc = machine_desc.strip()
            # Or, if there's literally only one quote at the end
            if machine_desc.count('"') == 1 and machine_desc[-1] == '"':
                machine_desc = machine_desc[:-1]
        if len(machine_desc) > 2:
            if machine_desc[0] == '"' and machine_desc[-1] == '"':
                machine_desc = machine_desc.strip('"')
        logger.info(f"Auto-generated chat title is {len(machine_desc)} chars: {machine_desc=}")
        response_sequence.human_desc = machine_desc

    async def construct_response_sequence(response_content_json):
        nonlocal inference_model
        inference_model = history_db.merge(inference_model)

        inference_job = InferenceEventOrm(
            model_record_id=inference_model.id,
            reason="chat sequence",
            response_error="[haven't received/finalized response info yet]",
        )

        finalize_inference_job(inference_job, response_content_json)
        history_db.add(inference_job)
        history_db.commit()

        assistant_response = ChatMessageOrm(
            role="assistant",
            content=safe_get(response_content_json, "message", "content"),
            created_at=inference_job.response_created_at,
        )
        history_db.add(assistant_response)
        history_db.commit()

        # Add what we need for response_sequence
        original_sequence.user_pinned = False
        response_sequence.user_pinned = True

        history_db.add(original_sequence)
        history_db.add(response_sequence)

        response_sequence.current_message = assistant_response.id

        response_sequence.generated_at = inference_job.response_created_at
        response_sequence.generation_complete = response_content_json["done"]
        response_sequence.inference_job_id = inference_job.id
        if inference_job.response_error:
            response_sequence.inference_error = inference_job.response_error

        history_db.add(response_sequence)
        history_db.commit()

        # And complete the circular reference that really should be handled in the SQLAlchemy ORM
        inference_job = history_db.merge(inference_job)
        inference_job.parent_sequence = response_sequence.id

        # TODO: This is disabled while we figure out why the duplicate InferenceEvent never commits its response content
        if False and not inference_job.response_error:
            inference_job.response_error = (
                "this is a duplicate InferenceEvent, because do_generate_raw_templated will dump its own raws in. "
                "we're keeping this one because it's tied into the actual ChatSequence."
            )

        history_db.add(inference_job)
        history_db.commit()

        return {
            "new_sequence_id": response_sequence.id,
            "done": True,
        }

    async def add_json_suffix(primordial):
        all_chunks = []

        done_signaled: int = 0
        async for chunk in primordial:
            if chunk is None:
                yield orjson.dumps({
                    # Look this up in the JSON object, because the SQLAlchemy objects have long-expired.
                    "model": constructed_ollama_request_content_json["model"],
                    "created_at": datetime.now(tz=timezone.utc),
                    "response": "",
                    "done": False,
                })
                continue

            try:
                chunk_json = orjson.loads(chunk)
                if chunk_json["done"]:
                    done_signaled += 1
                    chunk_json["done"] = False
                    yield orjson.dumps(chunk_json)
                    all_chunks.append(chunk)
                    continue
            except Exception:
                logger.exception(f"/chat: Response decode to JSON failed, {len(all_chunks)=}")

            yield chunk
            all_chunks.append(chunk)
            if done_signaled > 0:
                logger.warning(f"/chat: Still yielding chunks after `done=True`")

        if not done_signaled:
            logger.warning(f"/chat: Finished streaming response without hitting `done=True`")

        # Construct our actual suffix
        consolidated_response = await consolidate_stream_sync(all_chunks, logger.warning)
        suffix_chunk = orjson.dumps(await construct_response_sequence(consolidated_response))
        yield suffix_chunk

    async def wrap_response(
            upstream_response: JSONStreamingResponse,
    ) -> JSONStreamingResponse:
        upstream_response._content_iterable = add_json_suffix(upstream_response._content_iterable)
        return upstream_response

    return await wrap_response(
        await do_proxy_chat_rag(
            empty_request,
            constructed_ollama_request_content_json,
            retrieval_label,
            history_db,
            audit_db,
            capture_chat_messages=False,
            status_holder=status_holder,
        ))


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post("/sequences/{sequence_id:int}/continue")
    async def sequence_continue(
            empty_request: starlette.requests.Request,
            sequence_id: ChatSequenceID,
            params: ContinueRequest,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ) -> JSONStreamingResponse:
        original_sequence = history_db.execute(
            select(ChatSequence)
            .filter_by(id=sequence_id)
        ).scalar_one()

        messages_list: list[ChatMessage] = \
            do_get_sequence(sequence_id, history_db, include_model_info_diffs=False)

        # Decide how to continue inference for this sequence
        inference_model: InferenceModelRecordOrm = \
            select_continuation_model(sequence_id, params.continuation_model_id, params.fallback_model_id, history_db)

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
                messages_list,
                original_sequence,
                inference_model,
                retrieval_label,
                status_holder,
                empty_request,
                history_db,
                audit_db,
            ),
            status_holder,
        )

    @router_ish.post("/sequences/{sequence_id:int}/extend")
    async def sequence_extend(
            empty_request: starlette.requests.Request,
            sequence_id: ChatSequenceID,
            params: ExtendRequest,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ) -> JSONStreamingResponse:
        # Manually fetch the message + model config history from our requests
        messages_list: list[ChatMessage] = \
            do_get_sequence(sequence_id, history_db, include_model_info_diffs=False)

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
        inference_model: InferenceModelRecordOrm = \
            select_continuation_model(sequence_id, params.continuation_model_id, params.fallback_model_id, history_db)

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
                messages_list,
                original_sequence if user_sequence.id is None else user_sequence,
                inference_model,
                retrieval_label,
                status_holder,
                empty_request,
                history_db,
                audit_db,
            ),
            status_holder,
        )
