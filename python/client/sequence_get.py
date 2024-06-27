import itertools
import json
import logging
from datetime import datetime, timezone, timedelta
from typing import Annotated, Iterable

import fastapi.routing
import jsondiff
import sqlalchemy
import starlette.requests
import starlette.responses
import starlette.status
from fastapi import Depends, Query
from sqlalchemy import select, or_, and_
from starlette.exceptions import HTTPException

from _util.json import JSONDict, DatetimeEncoder, CatchAllEncoder
from _util.typing import ChatSequenceID
from providers.inference_models.orm import FoundationModelRecordOrm, lookup_foundation_model_for_event_id
from .chat_message import ChatMessageOrm, ChatMessage, ChatMessageResponse
from .chat_sequence import ChatSequenceOrm, lookup_sequence_parents, ChatSequenceResponse, ChatSequence, InfoMessageOut
from .database import HistoryDB, get_db as get_history_db

logger = logging.getLogger(__name__)


def translate_model_info(model0: FoundationModelRecordOrm | None) -> InfoMessageOut:
    if model0 is None:
        return InfoMessageOut(
            role='model config',
            content="no info available",
        )

    return InfoMessageOut(
        role=f"[INFO] FoundationModelRecord for {model0.human_id}",
        content=json.dumps(dict(model0.model_dump()), indent=2, cls=DatetimeEncoder),
    )


def translate_model_info_diff(
        model0: FoundationModelRecordOrm | None,
        model1: FoundationModelRecordOrm,
) -> InfoMessageOut | None:
    if model0 is None:
        return translate_model_info(model1)

    if model0 == model1:
        return None

    if model0.human_id != model1.human_id:
        return InfoMessageOut(
            role=f"[INFO] Switched FoundationModel to {model1.human_id}",
            content=json.dumps(dict(model1.model_dump()), indent=2, cls=DatetimeEncoder),
        )

    m0_dict = dict(model0.model_dump())
    m1_dict = dict(model1.model_dump())
    if m0_dict == m1_dict:
        return None

    return InfoMessageOut(
        role='[INFO] FoundationModelRecords modified',
        content=json.dumps(
            jsondiff.diff(m0_dict, m1_dict), indent=2, cls=CatchAllEncoder,
        ),
    )


def fetch_messages_for_sequence(
        id: ChatSequenceID,
        history_db: HistoryDB,
        include_model_info_diffs: bool = False,
        include_sequence_info: bool = False,
) -> list[ChatMessage | ChatMessageResponse | InfoMessageOut]:
    messages_list: list[ChatMessage | InfoMessageOut] = []
    last_seen_model: FoundationModelRecordOrm | None = None

    sequence: ChatSequenceOrm
    for sequence in lookup_sequence_parents(id, history_db):
        message: ChatMessageOrm | None
        message = history_db.execute(
            select(ChatMessageOrm)
            .where(ChatMessageOrm.id == sequence.current_message)
        ).scalar_one_or_none()
        if message is not None:
            if include_sequence_info:
                augmented_message = ChatMessageResponse(
                    **ChatMessage.from_orm(message).model_dump(),
                    message_id=message.id,
                    sequence_id=sequence.id,
                )
                messages_list.append(augmented_message)
            else:
                message_out = ChatMessage.from_orm(message)
                messages_list.append(message_out)

        # For "debug" purposes, compute the diffs even if we don't render them
        if sequence.inference_job_id is not None:
            this_model = lookup_foundation_model_for_event_id(sequence.inference_job_id, history_db)
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
        sequence_orm: ChatSequenceOrm,
        history_db: HistoryDB,
) -> ChatSequenceResponse:
    response_data: dict = ChatSequence.from_orm(sequence_orm).model_dump()
    response_data["messages"] = fetch_messages_for_sequence(
        sequence_orm.id,
        history_db,
        include_model_info_diffs=True,
        include_sequence_info=True,
    )

    # Stick latest model name onto SequenceID, for client ease-of-display
    for sequence_node in lookup_sequence_parents(sequence_orm.id, history_db):
        model = lookup_foundation_model_for_event_id(sequence_node.inference_job_id, history_db)
        if model is not None:
            response_data["inference_model_id"] = model.id
            break

    # Check the DAG characteristics of this node
    with_dependents: sqlalchemy.Select = (
        select(ChatSequenceOrm.parent_sequence)
        .where(ChatSequenceOrm.parent_sequence.is_not(None))
        .group_by(ChatSequenceOrm.parent_sequence)
    )

    response_data["is_leaf_sequence"] = history_db.execute(
        select(ChatSequenceOrm.id)
        .where(and_(
            ChatSequenceOrm.id.not_in(with_dependents),
            ChatSequenceOrm.id == sequence_orm.id
        ))
    ).one_or_none() is not None

    def do_get_one_sequence_parent(sequence_id: ChatSequenceID) -> ChatSequenceID | None:
        match_object = history_db.execute(
            select(ChatSequenceOrm)
            .filter_by(id=sequence_id)
        ).scalar_one_or_none()

        return match_object.parent_sequence

    def get_multiple(sequence_id: ChatSequenceID) -> Iterable[ChatSequenceID]:
        current_sequence = sequence_id
        while current_sequence is not None:
            yield current_sequence
            current_sequence = do_get_one_sequence_parent(current_sequence)

    response_data["parent_sequences"] = list(get_multiple(sequence_orm.id))

    return ChatSequenceResponse(**response_data)


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.get("/sequences/.recent/as-ids")
    def fetch_recent_sequences_as_ids(
            lookback: Annotated[float | None, Query(description="Maximum age in seconds for returned items")] = None,
            limit: Annotated[int | None, Query(description="Maximum number of items to return")] = None,
            only_user_pinned: Annotated[bool | None, Query(description="Only include user_pinned sequences")] = None,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        query = (
            select(ChatSequenceOrm.id)
            .order_by(ChatSequenceOrm.generated_at.desc())
        )
        if lookback is not None:
            cutoff_time = datetime.now(tz=timezone.utc) - timedelta(seconds=lookback)
            query = query.where(ChatSequenceOrm.generated_at > cutoff_time)
        if limit is not None:
            query = query.limit(limit)
        if only_user_pinned:
            query = query.filter_by(user_pinned=only_user_pinned)

        matching_sequence_ids = history_db.execute(query).scalars()
        return {"sequence_ids": list(matching_sequence_ids)}

    @router_ish.get(
        "/sequences/.recent/as-json",
        description="Fetch recent ChatSequence content as JSON.\n"
                    "NB Returns nothing unless you specify one of the flags."
    )
    def fetch_recent_sequences_as_messages(
            lookback: Annotated[float | None, Query(description="Maximum age in seconds for returned items")] = None,
            limit: Annotated[int | None, Query(description="Maximum number of items to return")] = None,
            include_user_pinned: Annotated[bool | None, Query(description="Include user_pinned sequences")] = None,
            include_leaf_sequences: Annotated[
                bool | None, Query(description="Include sequences without dependents")] = None,
            include_all: Annotated[bool, Query(description="Overrides the other two flags")] = False,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        query = (
            select(ChatSequenceOrm)
            .order_by(ChatSequenceOrm.generated_at.desc())
        )
        if lookback is not None:
            cutoff_time = datetime.now(tz=timezone.utc) - timedelta(seconds=lookback)
            query = query.where(ChatSequenceOrm.generated_at > cutoff_time)
        if limit is not None:
            query = query.limit(limit)

        if include_all:
            pass

        else:
            where_clauses = []
            if include_user_pinned:
                where_clauses.append(ChatSequenceOrm.user_pinned == True)
            if include_leaf_sequences:
                # Set up an "inverse" query that lists every sequence_id in the parent_sequences column.
                with_dependents: sqlalchemy.Select = (
                    select(ChatSequenceOrm.parent_sequence)
                    .where(ChatSequenceOrm.parent_sequence.is_not(None))
                    .group_by(ChatSequenceOrm.parent_sequence)
                )

                where_clauses.append(ChatSequenceOrm.id.not_in(with_dependents))

            if where_clauses:
                query = query.where(or_(*where_clauses))

        return {"sequences": [
            emit_sequence_details(match_object, history_db)
            for match_object
            in history_db.execute(query).scalars()
        ]}

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

    @router_ish.get("/sequences/{sequence_id:int}/as-json")
    def fetch_sequence_as_messages(
            sequence_id: ChatSequenceID,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        match_object = history_db.execute(
            select(ChatSequenceOrm)
            .filter_by(id=sequence_id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(starlette.status.HTTP_404_NOT_FOUND, "No matching object")

        return emit_sequence_details(match_object, history_db)

    @router_ish.get("/sequences/{sequence_id:int}/parent")
    def get_one_sequence_parent(
            sequence_id: ChatSequenceID,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> JSONDict:
        match_object = history_db.execute(
            select(ChatSequenceOrm)
            .filter_by(id=sequence_id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(starlette.status.HTTP_404_NOT_FOUND, "No matching object")

        return {"sequence_id": match_object.parent_sequence}

    @router_ish.get("/sequences/{sequence_id:int}/parents")
    def get_sequence_parent(
            sequence_id: ChatSequenceID,
            limit: Annotated[int | None, Query()] = None,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> JSONDict:
        def do_get_one_sequence_parent(sequence_id: ChatSequenceID) -> ChatSequenceID | None:
            match_object = history_db.execute(
                select(ChatSequenceOrm)
                .filter_by(id=sequence_id)
            ).scalar_one_or_none()

            return match_object.parent_sequence

        def get_multiple() -> Iterable[ChatSequenceID]:
            current_sequence = sequence_id
            while current_sequence is not None:
                yield current_sequence
                current_sequence = do_get_one_sequence_parent(current_sequence)

        return {
            "sequence_ids": list(itertools.islice(get_multiple(), limit)),
        }

    @router_ish.post("/sequences/{sequence_id:int}/user_pinned")
    def set_sequence_user_pinned(
            sequence_id: ChatSequenceID,
            value: Annotated[bool, Query(description="Whether to pin or unpin")],
            history_db: HistoryDB = Depends(get_history_db),
    ) -> JSONDict:
        match_object = history_db.execute(
            select(ChatSequenceOrm)
            .filter_by(id=sequence_id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(starlette.status.HTTP_404_NOT_FOUND, "No matching object")

        match_object.user_pinned = value
        history_db.add(match_object)
        history_db.commit()

        return {
            "sequence_id": match_object.id,
            "user_pinned": match_object.user_pinned,
        }

    @router_ish.post("/sequences/{sequence_id:int}/human_desc")
    def set_sequence_human_desc(
            sequence_id: ChatSequenceID,
            value: Annotated[str, Query()],
            history_db: HistoryDB = Depends(get_history_db),
    ) -> JSONDict:
        match_object = history_db.execute(
            select(ChatSequenceOrm)
            .filter_by(id=sequence_id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(starlette.status.HTTP_404_NOT_FOUND, "No matching object")

        match_object.human_desc = value
        history_db.add(match_object)
        history_db.commit()

        return {
            "sequence_id": match_object.id,
            "human_desc": match_object.human_desc,
        }
