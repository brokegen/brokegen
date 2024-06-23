import json
import logging
from datetime import datetime, timezone, timedelta
from http.client import HTTPException
from typing import Annotated, Any, AsyncIterator, AsyncGenerator, Awaitable

import fastapi.routing
import starlette.requests
import starlette.responses
import starlette.status
from fastapi import Depends, Query
from pydantic import BaseModel
from sqlalchemy import select
from starlette.background import BackgroundTask

from _util.json import JSONDict
from _util.json_streaming import emit_keepalive_chunks
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, RoleName, PromptText, FoundationModelRecordID
from client.chat_message import ChatMessageOrm, ChatMessage
from client.chat_sequence import ChatSequence, lookup_sequence_parents
from client.database import HistoryDB, get_db as get_history_db
from inference.autonaming import autoname_sequence
from inference.routes_langchain import JSONStreamingResponse
from providers.inference_models.orm import FoundationModelRecordOrm, lookup_inference_model_for_event_id
from providers.registry import ProviderRegistry

logger = logging.getLogger(__name__)


class InfoMessageOut(BaseModel):
    """
    This class is a bridge between "real" user/assistant messages,
    and ModelConfigRecord changes.

    TODO: Once we've written client support to render config changes,
          remove this and replace with a real config change.
    """
    role: RoleName = 'model info'
    content: PromptText


def translate_model_info(model0: FoundationModelRecordOrm | None) -> InfoMessageOut:
    if model0 is None:
        return InfoMessageOut(
            role='model config',
            content="no info available",
        )

    return InfoMessageOut(
        role='model config',
        content=f"ModelConfigRecord: {json.dumps(model0.as_json(), indent=2)}"
    )


def translate_model_info_diff(
        model0: FoundationModelRecordOrm | None,
        model1: FoundationModelRecordOrm,
) -> InfoMessageOut | None:
    if model0 is None:
        return translate_model_info(model1)

    if model0 == model1:
        return None

    if model0.as_json() == model1.as_json():
        return None

    return InfoMessageOut(
        role='model config',
        # TODO: pip install jsondiff would make this simpler, and also dumber
        content=f"ModelRecordConfigs changed:\n"
                f"{json.dumps(model0.as_json(), indent=2)}\n"
                f"{json.dumps(model1.as_json(), indent=2)}"
    )


def fetch_messages_for_sequence(
        id: ChatSequenceID,
        history_db: HistoryDB,
        include_model_info_diffs: bool = False,
) -> list[ChatMessage | InfoMessageOut]:
    messages_list: list[ChatMessage | InfoMessageOut] = []
    last_seen_model: FoundationModelRecordOrm | None = None

    sequence: ChatSequence
    for sequence in lookup_sequence_parents(id, history_db):
        message = history_db.execute(
            select(ChatMessageOrm)
            .where(ChatMessageOrm.id == sequence.current_message)
        ).scalar_one_or_none()
        if message is not None:
            message_out = ChatMessage.from_orm(message)
            messages_list.append(message_out)

        # For "debug" purposes, compute the diffs even if we don't render them
        if sequence.inference_job_id is not None:
            this_model = lookup_inference_model_for_event_id(sequence.inference_job_id, history_db)
            if last_seen_model is not None:
                # Since we're iterating in child-to-parent order, dump diffs backwards if something changed.
                mdiff = translate_model_info_diff(last_seen_model, this_model)
                if mdiff is not None:
                    if include_model_info_diffs:
                        messages_list.append(mdiff)

            last_seen_model = this_model

    # End of iteration, populate "initial" model info, if needed
    if include_model_info_diffs:
        messages_list.append(translate_model_info(last_seen_model))

    return messages_list[::-1]


def emit_sequence_details(
        sequence: ChatSequence,
        history_db: HistoryDB,
        add_display_info: bool = True,
) -> ChatSequence | Any:
    # This modifies the SQLAlchemy object, when we should really have turned it into a JSON first.
    # TODO: Turn the `match_object` into a JSON object first.
    sequence.messages = fetch_messages_for_sequence(sequence.id, history_db, include_model_info_diffs=True)

    # Stick latest model name onto SequenceID, for client ease-of-display
    for sequence_node in lookup_sequence_parents(sequence.id, history_db):
        model = lookup_inference_model_for_event_id(sequence_node.inference_job_id, history_db)
        if model is not None:
            sequence.inference_model_id = model.id
            break

    return sequence


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.get("/sequences/.recent/as-messages")
    def fetch_recent_sequences_as_messages(
            lookback: Annotated[float | None, Query(description="Maximum age in seconds for returned items")] = None,
            limit: Annotated[int | None, Query(description="Maximum number of items to return")] = None,
            only_user_pinned: Annotated[bool | None, Query(description="Only include user_pinned sequences")] = None,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        query = (
            select(ChatSequence)
            .order_by(ChatSequence.generated_at.desc())
        )
        if lookback is not None:
            reference_time = datetime.now(tz=timezone.utc) - timedelta(seconds=lookback)
            query = query.where(ChatSequence.generated_at > reference_time)
        if limit is not None:
            query = query.limit(limit)
        if only_user_pinned:
            query = query.filter_by(only_user_pinned=only_user_pinned)

        return {"sequences": [
            emit_sequence_details(match_object, history_db)
            for match_object
            in history_db.execute(query).scalars()
        ]}

    @router_ish.get("/sequences/.recent/as-ids")
    def fetch_recent_sequences_as_ids(
            lookback: Annotated[float | None, Query(description="Maximum age in seconds for returned items")] = None,
            limit: Annotated[int | None, Query(description="Maximum number of items to return")] = None,
            only_user_pinned: Annotated[bool | None, Query(description="Only include user_pinned sequences")] = None,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        query = (
            select(ChatSequence.id)
            .order_by(ChatSequence.generated_at.desc())
        )
        if lookback is not None:
            reference_time = datetime.now(tz=timezone.utc) - timedelta(seconds=lookback)
            query = query.where(ChatSequence.generated_at > reference_time)
        if limit is not None:
            query = query.limit(limit)
        if only_user_pinned:
            query = query.filter_by(user_pinned=only_user_pinned)

        matching_sequence_ids = history_db.execute(query).scalars()
        return {"sequence_ids": list(matching_sequence_ids)}

    @router_ish.get("/sequences/{sequence_id:int}")
    def get_sequence_as_messages_redirect(
            request: fastapi.Request,
            sequence_id: ChatSequenceID,
    ) -> starlette.responses.RedirectResponse:
        return starlette.responses.RedirectResponse(
            request.url_for("fetch_sequence_as_messages",
                            sequence_id=sequence_id),
            status_code=starlette.status.HTTP_301_MOVED_PERMANENTLY,
        )

    @router_ish.get("/sequences/{sequence_id:int}/as-messages")
    def fetch_sequence_as_messages(
            sequence_id: ChatSequenceID,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        match_object = history_db.execute(
            select(ChatSequence)
            .filter_by(id=sequence_id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(starlette.status.HTTP_404_NOT_FOUND, "No matching object")

        return emit_sequence_details(match_object, history_db)

    @router_ish.get("/sequences/{sequence_id:int}/parent")
    def get_sequence_parent(
            sequence_id: ChatSequenceID,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> ChatSequenceID | None:
        match_object = history_db.execute(
            select(ChatSequence)
            .filter_by(id=sequence_id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(starlette.status.HTTP_404_NOT_FOUND, "No matching object")

        return match_object.parent_sequence

    @router_ish.post("/sequences/{sequence_id:int}/user_pinned")
    def set_sequence_pinned(
            sequence_id: ChatSequenceID,
            value: Annotated[bool, Query(description="Whether to pin or unpin")] = True,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        match_object = history_db.execute(
            select(ChatSequence)
            .filter_by(id=sequence_id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(starlette.status.HTTP_404_NOT_FOUND, "No matching object")

        match_object.user_pinned = value
        history_db.add(match_object)
        history_db.commit()

        return starlette.responses.Response(status_code=starlette.status.HTTP_204_NO_CONTENT)

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
            select(ChatSequence)
            .filter_by(id=sequence_id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(starlette.status.HTTP_404_NOT_FOUND, "No matching object")

        status_holder = ServerStatusHolder(f"/sequences/{sequence_id}/autoname: setting up")

        async def do_autoname(
                sequence: ChatSequence,
                history_db: HistoryDB,
        ) -> PromptText | None:
            autoname: PromptText | None = await autoname_sequence(
                sequence,
                preferred_autonaming_model,
                status_holder,
                history_db,
                registry,
            )
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
        ) -> AsyncGenerator[JSONDict]:
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
