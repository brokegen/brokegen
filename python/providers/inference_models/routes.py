from datetime import datetime, timezone
from http.client import HTTPException

import fastapi.routing
import orjson
from fastapi import FastAPI, Depends
from pydantic import BaseModel, ConfigDict
from sqlalchemy import select

from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecordOrm, InferenceModelRecordID, \
    lookup_inference_model_record, lookup_inference_model_record_detailed, InferenceModelAddRequest
from providers.orm import ProviderRecordOrm, ProviderRecord, ProviderAddRequest


class InferenceModelAddResponse(BaseModel):
    model_id: InferenceModelRecordID
    just_created: bool

    # Disable Pydantic warning where `model_` prefixed items are reserved.
    # TODO: Figure out how to use Field(alias=...)
    model_config = ConfigDict(
        protected_namespaces=(),
    )


def make_provider_record(
        provider_in: ProviderAddRequest,
        endpoint: str,
        history_db: HistoryDB,
) -> ProviderRecord:
    provider_identifiers_dict = {
        "name": "[external upload]",
        "endpoint": endpoint,
    }
    provider_identifiers_dict.update(orjson.loads(provider_in.identifiers))
    provider_identifiers = orjson.dumps(provider_identifiers_dict, option=orjson.OPT_SORT_KEYS)

    # Check for existing matches
    maybe_provider = history_db.execute(
        select(ProviderRecordOrm)
        .where(ProviderRecordOrm.identifiers == provider_identifiers)
    ).scalar_one_or_none()
    if maybe_provider is not None:
        return ProviderRecord.from_orm(maybe_provider)

    optional_kwargs = {}
    if provider_in.machine_info:
        optional_kwargs["machine_info"] = provider_in.machine_info
    if provider_in.human_info:
        optional_kwargs["human_info"] = provider_in.human_info

    new_provider = ProviderRecordOrm(
        identifiers=provider_identifiers,
        created_at=provider_in.created_at or datetime.now(tz=timezone.utc),
        **optional_kwargs,
    )
    history_db.add(new_provider)
    history_db.commit()

    return ProviderRecord.from_orm(new_provider)


def install_routes(app: FastAPI):
    router = fastapi.routing.APIRouter()

    @router.post(
        "/models",
        response_model=InferenceModelAddResponse,
    )
    async def create_model(
            model_in: InferenceModelAddRequest,
            provider_in: ProviderAddRequest,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> InferenceModelAddResponse:
        provider_record: ProviderRecord = make_provider_record(provider_in, "POST /models", history_db)
        maybe_model = lookup_inference_model_record(provider_record, model_in.human_id, history_db)
        if maybe_model is None:
            # Check in-depth to see if we have anything actually-identical
            maybe_model1 = lookup_inference_model_record_detailed(model_in, history_db)
            if maybe_model1 is not None:
                maybe_model1.merge_in_updates(model_in)
                history_db.add(maybe_model)
                history_db.commit()

                return InferenceModelAddResponse(
                    model_id=maybe_model1.id,
                    just_created=False,
                )

        new_model = InferenceModelRecordOrm(
            **model_in.model_dump(),
        )
        history_db.add(new_model)
        history_db.commit()

        return InferenceModelAddResponse(
            model_id=new_model.id,
            just_created=True
        )

    @router.get("/models/{id:int}")
    def get_model_config(
            id: int,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        match_object = history_db.execute(
            select(InferenceModelRecordOrm)
            .filter_by(id=id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(400, "No matching object")

        return match_object

    app.include_router(router)
