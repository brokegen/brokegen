from datetime import datetime, timezone
from http.client import HTTPException
from typing import Optional

import fastapi.routing
import orjson
from fastapi import FastAPI, Depends
from pydantic import BaseModel, ConfigDict
from sqlalchemy import select

from providers.database import HistoryDB, get_db as get_history_db, ModelConfigRecord, ModelConfigID, \
    ProviderRecordOrm
from providers.registry import ProviderRecord


class ModelIn(BaseModel):
    human_id: str
    seen_at: Optional[datetime] = None

    provider_identifiers: dict
    # These fields are only useful when we have to construct a new provider from the above
    provider_created_at: Optional[datetime] = None
    provider_machine_info: Optional[dict] = None
    provider_human_info: Optional[str] = None

    model_config = ConfigDict(
        extra='allow',
        frozen=True,
    )


class ModelAddResponse(BaseModel):
    model_id: ModelConfigID
    just_created: bool

    # Disable Pydantic warning where `model_` prefixed items are reserved.
    # TODO: We should find a way to name/rename the fields on the fly.
    model_config = ConfigDict(
        protected_namespaces=(),
    )


def make_provider_record(
        model_info: ModelIn,
        endpoint: str,
        history_db: HistoryDB,
) -> ProviderRecord:
    provider_identifiers_dict = {
        "name": "[external upload]",
        "endpoint": endpoint,
    }
    provider_identifiers_dict.update(model_info.provider_identifiers)
    provider_identifiers = orjson.dumps(provider_identifiers_dict, option=orjson.OPT_SORT_KEYS)

    # Check for existing matches
    maybe_provider = history_db.execute(
        select(ProviderRecordOrm)
        .where(ProviderRecordOrm.identifiers == provider_identifiers)
    ).scalar_one_or_none()
    if maybe_provider is not None:
        return ProviderRecord.from_orm(maybe_provider)

    optional_kwargs = {}
    if model_info.provider_machine_info:
        optional_kwargs["machine_info"] = model_info.provider_machine_info
    if model_info.provider_human_info:
        optional_kwargs["human_info"] = model_info.provider_human_info

    new_provider = ProviderRecordOrm(
        identifiers=provider_identifiers,
        created_at=model_info.provider_created_at or datetime.now(tz=timezone.utc),
        **optional_kwargs,
    )
    history_db.add(new_provider)
    history_db.commit()

    return ProviderRecord.from_orm(new_provider)


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
        provider_record: ProviderRecord = make_provider_record(model_info, "POST /models", history_db)

        # TODO: Deduplicate this against history.ollama.models.fetch_model_record
        maybe_model = history_db.execute(
            select(ModelConfigRecord)
            # NB We must use the new executor info because `sorted_`
            .where(ModelConfigRecord.provider_identifiers == provider_record.identifiers,
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
            provider_identifiers=provider_record.identifiers,
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
