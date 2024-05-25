from datetime import datetime, timezone
from http.client import HTTPException
from typing import Optional

import fastapi.routing
import orjson
from fastapi import FastAPI, Depends
from pydantic import BaseModel, ConfigDict
from sqlalchemy import select

from history.shared.database import HistoryDB, get_db as get_history_db, ModelConfigRecord, ModelConfigID, \
    ExecutorConfigRecord
from history.shared.json import JSONDict


class ModelIn(BaseModel):
    human_id: str
    seen_at: Optional[datetime] = None
    executor_info: Optional[dict] = None
    static_model_info: Optional[dict] = None


class ModelAddResponse(BaseModel):
    model_id: ModelConfigID
    just_created: bool

    # Disable Pydantic warning where `model_` prefixed items are reserved.
    # TODO: We should find a way to name/rename the fields on the fly.
    model_config = ConfigDict(
        protected_namespaces=(),
    )


def construct_executor(
        executor_info: JSONDict,
        created_at: datetime | None,
) -> ExecutorConfigRecord:
    history_db: HistoryDB = next(get_history_db())
    sorted_executor_info: JSONDict = orjson.loads(
        orjson.dumps(executor_info, option=orjson.OPT_SORT_KEYS)
    )

    maybe_executor = history_db.execute(
        select(ExecutorConfigRecord)
        .where(ExecutorConfigRecord.executor_info == sorted_executor_info)
    ).scalar_one_or_none()
    if maybe_executor is not None:
        return maybe_executor

    new_executor = ExecutorConfigRecord(
        executor_info=sorted_executor_info,
        created_at=created_at or datetime.now(tz=timezone.utc),
    )
    history_db.add(new_executor)
    history_db.commit()

    return new_executor


def install_routes(app: FastAPI):
    router = fastapi.routing.APIRouter()

    @router.post(
        "/models",
        response_model=ModelAddResponse,
    )
    async def create_model(
            model_info: ModelIn,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> ModelAddResponse:
        if model_info.executor_info is None:
            raise HTTPException(400, "Must populate `executor_info` field")

        sorted_executor = construct_executor(model_info.executor_info, model_info.seen_at)

        # TODO: Deduplicate this against history.ollama.models.fetch_model_record
        maybe_model = history_db.execute(
            select(ModelConfigRecord)
            # NB We must use the new executor info because `sorted_`
            .where(ModelConfigRecord.executor_info == sorted_executor.executor_info,
                   ModelConfigRecord.human_id == model_info.human_id)
            .order_by(ModelConfigRecord.last_seen)
            .limit(1)
        ).scalar_one_or_none()
        if maybe_model is not None:
            # Update the last-seen date, if needed
            if model_info.seen_at is not None:
                if model_info.seen_at > maybe_model.last_seen:
                    maybe_model.last_seen = model_info.seen_at
                    history_db.add(maybe_model)
                    history_db.commit()

            return ModelAddResponse(
                model_id=maybe_model.id,
                just_created=False,
            )

        new_model = ModelConfigRecord(
            human_id=model_info.human_id,
            first_seen_at=model_info.seen_at,
            last_seen=model_info.seen_at,
            executor_info=model_info.executor_info,
            static_model_info=model_info.static_model_info,
        )

        history_db.add(new_model)
        history_db.commit()

        return ModelAddResponse(
            model_id=new_model.id,
            just_created=True
        )

    @router.get("/models/{id:int}")
    def get_model_config(
            id: int,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        match_object = history_db.execute(
            select(ModelConfigRecord)
            .filter_by(id=id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(400, "No matching object")

        return match_object

    app.include_router(router)
