import logging
from datetime import datetime, timezone
from typing import Annotated, AsyncIterator, AsyncGenerator, Awaitable

import fastapi.routing
import starlette.requests
import starlette.responses
import starlette.status
from fastapi import Depends, Query
from sqlalchemy import select
from starlette.background import BackgroundTask
from starlette.exceptions import HTTPException

from _util.json import JSONDict
from _util.json_streaming import emit_keepalive_chunks
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, PromptText, FoundationModelRecordID
from client.chat_sequence import ChatSequenceOrm
from client.database import HistoryDB, get_db as get_history_db
from inference.routes_langchain import JSONStreamingResponse
from providers.registry import ProviderRegistry
from .bridge import autoname_sequence

logger = logging.getLogger(__name__)


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post("/sequences/{sequence_id:int}/autoname")
    async def request_sequence_autoname(
            sequence_id: ChatSequenceID,
            preferred_autonaming_model: Annotated[FoundationModelRecordID | None, Query(
                description="Requested foundation model to use for autonaming"
            )] = None,
            wait_for_response: bool = False,
            history_db: HistoryDB = Depends(get_history_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        match_object = history_db.execute(
            select(ChatSequenceOrm)
            .filter_by(id=sequence_id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(starlette.status.HTTP_404_NOT_FOUND, "No matching object")

        status_holder = ServerStatusHolder(f"/sequences/{sequence_id}/autoname: setting up")

        async def do_autoname(
                sequence: ChatSequenceOrm,
                history_db: HistoryDB,
        ) -> PromptText | None:
            autoname: PromptText | None

            try:
                autoname = await autoname_sequence(
                    sequence,
                    preferred_autonaming_model,
                    status_holder,
                    history_db,
                    registry,
                )
            except (RuntimeError, ValueError, HTTPException):
                autoname = None

            if autoname is not None:
                sequence.human_desc = autoname
                history_db.add(sequence)
                history_db.commit()

                status_holder.set(f"Done autonaming, chat title is {len(autoname)} chars: {autoname=}")
                return autoname
            else:
                status_holder.set(f"Failed autonaming, chat title is unchanged")
                return autoname

        async def nonblocking_response_maker(
                real_response_maker: Awaitable[PromptText | None],
        ) -> AsyncIterator[JSONDict]:
            yield {
                "autoname": await real_response_maker,
                "done": True,
            }

        async def do_keepalive(
                primordial: AsyncIterator[JSONDict],
        ) -> AsyncGenerator[JSONDict, None]:
            start_time = datetime.now(tz=timezone.utc)
            async for chunk in emit_keepalive_chunks(primordial, 4.9, None):
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

        if wait_for_response:
            awaitable: Awaitable[PromptText | None] = do_autoname(match_object, history_db)
            iter0: AsyncIterator[JSONDict] = nonblocking_response_maker(awaitable)
            iter1: AsyncIterator[JSONDict] = do_keepalive(iter0)
            return JSONStreamingResponse(
                content=iter1,
                status_code=218,
            )

        else:
            return starlette.responses.Response(
                status_code=starlette.status.HTTP_202_ACCEPTED,
                background=BackgroundTask(lambda: do_autoname(match_object, history_db)),
            )
