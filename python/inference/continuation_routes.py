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
from _util.json_streaming import JSONStreamingResponse, emit_keepalive_chunks
from _util.status import ServerStatusHolder, StatusContext
from _util.typing import ChatSequenceID, PromptText
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from client.database import HistoryDB, get_db as get_history_db
from inference.continuation import ContinueRequest, select_continuation_model
from providers.foundation_models.orm import FoundationModelRecordOrm
from providers.registry import ProviderRegistry, BaseProvider
from retrieval.faiss.knowledge import get_knowledge, KnowledgeSingleton
from retrieval.faiss.retrieval import RetrievalLabel, RetrievalPolicy, SimpleRetrievalPolicy, SummarizingRetrievalPolicy

logger = logging.getLogger(__name__)


async def with_retrieval(
        retrieval_label: RetrievalLabel,
        status_holder: ServerStatusHolder | None = None,
        knowledge: KnowledgeSingleton = get_knowledge(),
) -> PromptText | None:
    with StatusContext(f"Retrieving documents with {retrieval_label}", status_holder):
        real_retrieval_policy: RetrievalPolicy | None = None

        if retrieval_label.retrieval_policy == "skip":
            real_retrieval_policy = None
        elif retrieval_label.retrieval_policy == "simple":
            real_retrieval_policy = SimpleRetrievalPolicy(knowledge)
        elif retrieval_label.retrieval_policy == "summarizing":
            init_kwargs = {
                "knowledge": knowledge,
            }
            if retrieval_label.retrieval_search_args is not None:
                init_kwargs["search_args_json"] = orjson.loads(retrieval_label.retrieval_search_args)

            real_retrieval_policy = SummarizingRetrievalPolicy(**init_kwargs)

        if real_retrieval_policy is not None:
            if retrieval_label.preferred_embedding_model is not None:
                logger.warning(f"Ignoring requested embedding model, since we don't support overrides")

            logger.error(f"RAG not implemented yet")
            return None
            # return await real_retrieval_policy.parse_chat_history(
            #     chat_messages, generate_helper_fn, status_holder,
            # )

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
                retrieval_context=with_retrieval(retrieval_label, status_holder),
                status_holder=status_holder,
                history_db=history_db,
                audit_db=audit_db,
            )

        async def nonblocking_response_maker(
                real_response_maker: Awaitable[AsyncIterator[JSONDict]],
        ) -> AsyncIterator[JSONDict]:
            async for item in (await real_response_maker):
                yield item

        async def do_keepalive(
                primordial: AsyncIterator[JSONDict],
        ) -> AsyncIterator[JSONDict]:
            start_time = datetime.now(tz=timezone.utc)
            async for chunk in emit_keepalive_chunks(primordial, 0.5, None):
                if chunk is None:
                    current_time = datetime.now(tz=timezone.utc)
                    yield {
                        "done": False,
                        "status": status_holder.get(),
                        "created_at": current_time.isoformat() + "Z",
                        "elapsed": str(current_time - start_time),
                    }

                else:
                    yield chunk

                if await request.is_disconnected():
                    logger.fatal(f"Detected client disconnection! Ignoring, because we want inference to continue.")

        awaitable: Awaitable[AsyncIterator[JSONDict]] = real_response_maker()
        iter0: AsyncIterator[JSONDict] = nonblocking_response_maker(awaitable)
        iter1: AsyncIterator[JSONDict] = do_keepalive(iter0)
        return JSONStreamingResponse(
            content=iter1,
            status_code=218,
        )
