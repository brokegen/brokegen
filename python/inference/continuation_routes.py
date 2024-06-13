import asyncio
import logging
from datetime import datetime, timezone
from typing import Awaitable, AsyncIterator, AsyncGenerator

import fastapi.routing
import orjson
import starlette.datastructures
import starlette.datastructures
import starlette.requests
import starlette.requests
from fastapi import Depends, HTTPException
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
from retrieval.faiss.retrieval import RetrievalLabel
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm

logger = logging.getLogger(__name__)


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post("/v2/sequences/{sequence_id:int}/continue")
    async def sequence_continue(
            request: starlette.requests.Request,
            sequence_id: ChatSequenceID,
            params: ContinueRequest,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ) -> JSONStreamingResponse:
        status_holder = ServerStatusHolder(
            f"{request.url_for('sequence_continue', sequence_id=sequence_id)}: setting up"
        )

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
                select_continuation_model(sequence_id, params.continuation_model_id, params.fallback_model_id, history_db)

            nonlocal status_holder
            status_holder.push(
                f"/sequences/{sequence_id}/continue: processing on {inference_model.human_id}")

            # And RetrievalLabel
            retrieval_label = RetrievalLabel(
                retrieval_policy=params.retrieval_policy,
                retrieval_search_args=params.retrieval_search_args,
                preferred_embedding_model=params.preferred_embedding_model,
            )

            inference_model_human_id = safe_get(orjson.loads(await request.body()), "model")
            status_holder.push(f"Received /api/chat request for {inference_model_human_id}, processing")

            yield {"done": True}

        async def nonblocking_response_maker() -> AsyncIterator[JSONDict]:
            # TODO: This one is not gonna be async.
            async for item in real_response_maker():
                yield item

        async def do_keepalive(
                primordial: AsyncIterator[JSONDict],
        ) -> AsyncGenerator[JSONDict, None]:
            async for chunk in emit_keepalive_chunks(primordial, 2.0, None):
                if chunk is None:
                    yield orjson.dumps({
                        "created_at": datetime.now(tz=timezone.utc),
                        "done": False,
                        "status": status_holder.get(),
                    })
                    continue

                yield orjson.dumps(chunk)

        return JSONStreamingResponse(
            content=do_keepalive(nonblocking_response_maker()),
            status_code=218,
        )

    @router_ish.post("/v2/sequences/{sequence_id:int}/add/{message_id:int}")
    async def sequence_add(
            sequence_id: ChatSequenceID,
            message_id: ChatMessageID,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        """
        This just stacks a new user message onto the end of our chain.

        Rely on /continue to run any inference.
        """
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

        maybe_message = lookup_chat_message(message_id, history_db)
        if maybe_message is None:
            raise HTTPException(400, f"Can't find ChatMessage#{message_id}")

        user_sequence.current_message = maybe_message.id
        user_sequence.generation_complete = True

        # Mark this user response as the current up-to-date
        user_sequence.user_pinned = original_sequence.user_pinned
        original_sequence.user_pinned = False

        history_db.add(original_sequence)
        history_db.add(user_sequence)
        history_db.commit()

        return {"sequence_id": user_sequence.id}
