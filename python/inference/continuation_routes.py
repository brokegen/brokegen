import asyncio
import logging
from datetime import datetime, timezone
from time import sleep
from typing import Awaitable, AsyncIterator, AsyncGenerator, Annotated

import fastapi.routing
import orjson
import starlette.datastructures
import starlette.datastructures
import starlette.requests
import starlette.requests
from fastapi import Depends, HTTPException, Body
from sqlalchemy import select
from starlette.background import BackgroundTask

from _util.json import JSONDict, safe_get
from _util.json_streaming import JSONStreamingResponse, emit_keepalive_chunks
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, ChatMessageID
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from client.database import ChatMessageOrm, ChatSequence, lookup_chat_message, ChatMessage
from client.sequence_get import do_get_sequence
from inference.continuation import ContinueRequest, ExtendRequest, select_continuation_model
from providers.registry import ProviderRegistry, BaseProvider
from retrieval.faiss.retrieval import RetrievalLabel
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm

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

        async def real_response_maker():
            # DEBUG: Check that everyone is responsive during long waits
            await asyncio.sleep(10)

            original_sequence = history_db.execute(
                select(ChatSequence)
                .filter_by(id=sequence_id)
            ).scalar_one()

            messages_list: list[ChatMessage] = \
                do_get_sequence(sequence_id, history_db, include_model_info_diffs=False)

            # Decide how to continue inference for this sequence
            inference_model: InferenceModelRecordOrm = \
                select_continuation_model(sequence_id, parameters.continuation_model_id, parameters.fallback_model_id, history_db)
            provider: BaseProvider | None = registry.provider_from(inference_model)

            nonlocal status_holder
            status_holder.push(f"{function_id}: processing on {inference_model.human_id}")

            # And RetrievalLabel
            retrieval_label = RetrievalLabel(
                retrieval_policy=parameters.retrieval_policy,
                retrieval_search_args=parameters.retrieval_search_args,
                preferred_embedding_model=parameters.preferred_embedding_model,
            )

            inference_model_human_id = safe_get(orjson.loads(await request.body()), "model")
            status_holder.push(f"{function_id}: processing request with {inference_model_human_id}")

            yield {"done": True}

        async def nonblocking_response_maker() -> AsyncIterator[JSONDict]:
            # TODO: This one is not gonna be async.
            async for item in real_response_maker():
                yield item

        async def do_keepalive(
                primordial: AsyncIterator[JSONDict],
        ) -> AsyncGenerator[JSONDict, None]:
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
            content=do_keepalive(nonblocking_response_maker()),
            status_code=218,
        )
