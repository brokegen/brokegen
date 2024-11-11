import functools
import logging
from datetime import datetime, timezone
from typing import AsyncIterator, Annotated, Awaitable

import fastapi.routing
import orjson
import starlette.datastructures
import starlette.datastructures
import starlette.requests
import starlette.requests
from fastapi import Depends, Body

from _util.json import JSONDict
from _util.json_streaming import JSONStreamingResponse, emit_keepalive_chunks, NDJSONStreamingResponse
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import ChatSequenceID, PromptText, GenerateHelper, InferenceReason
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from client.database import HistoryDB, get_db as get_history_db
from client.message import ChatMessage
from client.sequence_get import fetch_messages_for_sequence
from providers.foundation_models.orm import FoundationModelRecordOrm
from providers.registry import ProviderRegistry, BaseProvider, InferenceOptions, openai_consolidator, \
    ollama_consolidator
from retrieval.faiss.knowledge import get_knowledge, KnowledgeSingleton
from retrieval.faiss.retrieval import RetrievalLabel, RetrievalPolicy, \
    SummarizingRetrievalPolicy, SomeMessageSimilarity, AllMessageSimilarity
from .continuation import ContinueRequest, select_continuation_model

logger = logging.getLogger(__name__)


async def with_retrieval(
        retrieval_label: RetrievalLabel,
        messages_list: list[ChatMessage],
        generate_helper_fn: GenerateHelper,
        status_holder: ServerStatusHolder | None = None,
        knowledge: KnowledgeSingleton = get_knowledge(),
) -> PromptText | None:
    with StatusContext(f"Retrieving documents with {retrieval_label}", status_holder):
        real_retrieval_policy: RetrievalPolicy | None = None
        search_kwargs: dict = {}

        try:
            search_kwargs = orjson.loads(retrieval_label.retrieval_search_args)
        except ValueError:
            if retrieval_label.retrieval_search_args:
                logger.warning(f"Invalid retrieval_search_args, ignoring: {retrieval_label.retrieval_search_args}")

        # Now that we've set up default args, actually construct a RetrievalPolicy
        if retrieval_label.retrieval_policy == "skip":
            real_retrieval_policy = None

        elif retrieval_label.retrieval_policy == "simple":
            real_retrieval_policy = SomeMessageSimilarity(
                1, knowledge=knowledge, search_type="similarity", search_kwargs=search_kwargs)

        elif retrieval_label.retrieval_policy == "simple-3":
            real_retrieval_policy = SomeMessageSimilarity(
                3, knowledge=knowledge, search_type="similarity", search_kwargs=search_kwargs)

        elif retrieval_label.retrieval_policy == "simple-all":
            real_retrieval_policy = AllMessageSimilarity(knowledge, "similarity", search_kwargs)

        elif retrieval_label.retrieval_policy == "summarizing":
            real_retrieval_policy = SummarizingRetrievalPolicy(knowledge, "mmr", search_kwargs=search_kwargs)

        if real_retrieval_policy is not None:
            if retrieval_label.preferred_embedding_model is not None:
                logger.warning(f"TODO: Ignoring requested embedding model, since we don't support overrides")

            return await real_retrieval_policy.parse_chat_history(
                messages_list, generate_helper_fn, status_holder,
            )

        return None


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post("/sequences/{sequence_id:int}/continue-v2")
    async def sequence_continue_v2(
            request: starlette.requests.Request,
            sequence_id: ChatSequenceID,
            parameters: Annotated[ContinueRequest, Body],
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ) -> JSONStreamingResponse:
        function_id = request.url_for('sequence_continue_v2', sequence_id=sequence_id)
        status_holder = ServerStatusHolder(f"{function_id}: setting up")

        # TODO: Is it possible to make type checking work against a Protocol?
        generate: GenerateHelper

        async def generate(
                inference_reason: InferenceReason,
                system_message: PromptText | None,
                user_prompt: PromptText,
                assistant_response: PromptText | None,
                inference_model: FoundationModelRecordOrm,
                provider: BaseProvider,
        ) -> PromptText:
            inference_options: InferenceOptions = InferenceOptions(
                override_system_prompt=system_message,
                seed_assistant_response=assistant_response,
            )

            messages_list: list[ChatMessage] = [
                ChatMessage(role="user", content=user_prompt or "")
            ]

            iter0: AsyncIterator[JSONDict] = await provider.do_chat_nolog(
                messages_list,
                inference_model,
                inference_options,
                status_holder,
                history_db,
                audit_db,
            )

            ollama_response: str = ""
            openai_response: str = ""

            async for chunk in iter0:
                ollama_response = ollama_consolidator(chunk, ollama_response)
                openai_response = openai_consolidator(chunk, openai_response)

            return ollama_response or openai_response

        def real_response_maker() -> Awaitable[AsyncIterator[JSONDict]]:
            # Decide how to continue inference for this sequence
            inference_model: FoundationModelRecordOrm = \
                select_continuation_model(sequence_id, parameters.continuation_model_id, parameters.fallback_model_id,
                                          history_db)
            provider: BaseProvider | None = registry.provider_from(inference_model)

            nonlocal status_holder
            status_holder.push(f"{function_id}: processing on {inference_model.human_id}")

            # And RetrievalLabel
            retrieval_label = RetrievalLabel(
                retrieval_policy=parameters.retrieval_policy,
                retrieval_search_args=parameters.retrieval_search_args,
                preferred_embedding_model=parameters.preferred_embedding_model,
            )

            return provider.chat(
                sequence_id=sequence_id,
                inference_model=inference_model,
                inference_options=parameters,
                retrieval_context=with_retrieval(
                    retrieval_label=retrieval_label,
                    messages_list=fetch_messages_for_sequence(sequence_id, history_db, include_model_info_diffs=False),
                    generate_helper_fn=functools.partial(generate, inference_model=inference_model, provider=provider),
                    status_holder=status_holder),
                status_holder=status_holder,
                history_db=history_db,
                audit_db=audit_db,
            )

        async def nonblocking_response_maker(
                response_maker_awaitable: Awaitable[AsyncIterator[JSONDict]],
        ) -> AsyncIterator[JSONDict]:
            try:
                async for item in (await response_maker_awaitable):
                    yield item

            except Exception as e:
                logger.warning(f"{type(e)}: {str(e)}")

                # NB This eventually triggers a RuntimeWarning: coroutine 'with_retrieval' was never awaited
                #    (which resolves to `response_maker_awaitable` here).
                # TODO: `await`/handle the coroutine correctly on exceptions, especially for `NotImplementedError`
                yield {
                    "error": str(e),
                    "done": True,
                }

        async def do_keepalive(
                primordial: AsyncIterator[JSONDict],
        ) -> AsyncIterator[JSONDict]:
            chunks_received: int = 0

            start_time = datetime.now(tz=timezone.utc)
            async for chunk in emit_keepalive_chunks(primordial, 0.5, None):
                if chunk is None:
                    current_time = datetime.now(tz=timezone.utc)
                    yield {
                        "created_at": current_time.isoformat() + "Z",
                        "elapsed": str(current_time - start_time),
                        "done": False,
                        "status": status_holder.get(),
                    }

                else:
                    chunks_received += 1
                    yield chunk

            elapsed_time = datetime.now(tz=timezone.utc) - start_time
            logger.debug("sequence_continue_v2 do_keepalive(): end of inference iterator"
                         f", {chunks_received} chunks in {elapsed_time.total_seconds():_.3f} seconds")

        awaitable: Awaitable[AsyncIterator[JSONDict]] = real_response_maker()
        iter0: AsyncIterator[JSONDict] = nonblocking_response_maker(awaitable)
        iter1: AsyncIterator[JSONDict] = do_keepalive(iter0)
        return NDJSONStreamingResponse(
            content=iter1,
            status_code=218,
        )
