import asyncio
import logging
from datetime import datetime, timezone
from typing import AsyncIterator, AsyncGenerator, Annotated, Awaitable

import fastapi.routing
import orjson
import starlette.datastructures
import starlette.datastructures
import starlette.requests
import starlette.requests
from fastapi import Depends, Body

from _util.json import JSONDict
from _util.json_streaming import JSONStreamingResponse, emit_keepalive_chunks
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from inference.continuation import ContinueRequest, select_continuation_model
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm
from providers.registry import ProviderRegistry, BaseProvider
from retrieval.faiss.retrieval import RetrievalLabel

logger = logging.getLogger(__name__)


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post("/v2/sequences/{sequence_id:int}/continue")
    async def sequence_continue(
            request: starlette.requests.Request,
            sequence_id: ChatSequenceID,
            parameters: Annotated[ContinueRequest, Body],
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ) -> JSONStreamingResponse:
        function_id = request.url_for('sequence_continue', sequence_id=sequence_id)
        status_holder = ServerStatusHolder(f"{function_id}: setting up")

        async def real_response_maker() -> Awaitable[AsyncIterator[JSONDict]]:
            # DEBUG: Check that everyone is responsive during long waits
            await asyncio.sleep(3)

            # Decide how to continue inference for this sequence
            inference_model: InferenceModelRecordOrm = \
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

            return provider.chat(sequence_id, inference_model, retrieval_label, status_holder, history_db,
                                 audit_db)

        async def nonblocking_response_maker(
                real_response_maker: Awaitable[AsyncIterator[JSONDict]],
        ) -> AsyncIterator[JSONDict]:
            async for item in (await real_response_maker):
                yield item

        async def do_keepalive(
                primordial: AsyncIterator[JSONDict],
        ) -> AsyncGenerator[bytes, None]:
            async for chunk in emit_keepalive_chunks(primordial, 0.5, None):
                if chunk is None:
                    yield orjson.dumps({
                        "created_at": datetime.now(tz=timezone.utc),
                        "done": False,
                        "status": status_holder.get(),
                    }) + b'\n'

                    continue

                yield orjson.dumps(chunk) + b'\n'

        return JSONStreamingResponse(
            content=do_keepalive(nonblocking_response_maker(real_response_maker())),
            status_code=218,
        )
