from datetime import datetime, timezone
from http.client import HTTPException

import fastapi.routing
import orjson
from fastapi import Depends
from pydantic import BaseModel, ConfigDict
from sqlalchemy import select

from _util.typing import FoundationModelRecordID
from client.database import HistoryDB, get_db as get_history_db
from providers.foundation_models.orm import FoundationModelRecordOrm, lookup_foundation_model, \
    lookup_foundation_model_detailed, FoundationModelAddRequest
from providers.orm import ProviderRecordOrm, ProviderRecord, ProviderAddRequest


class FoundationModelAddResponse(BaseModel):
    model_id: FoundationModelRecordID
    just_created: bool

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
        return ProviderRecord.model_validate(maybe_provider)

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

    return ProviderRecord.model_validate(new_provider)


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post(
        "/models",
        response_model=FoundationModelAddResponse,
    )
    async def create_model(
            response: fastapi.Response,
            in_model: FoundationModelAddRequest,  # renamed due to pydantic namespace conflict
            in_provider: ProviderAddRequest,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> FoundationModelAddResponse:
        provider_record: ProviderRecord = make_provider_record(in_provider, "POST /models", history_db)
        # Replace the model_in's provider_identifiers with a sorted one
        in_model.provider_identifiers = provider_record.identifiers

        maybe_model = lookup_foundation_model(in_model.human_id, provider_record.identifiers, history_db)
        if maybe_model is not None:
            # Check in-depth to see if we have anything actually-identical
            maybe_model1 = lookup_foundation_model_detailed(in_model, history_db)
            if maybe_model1 is not None:
                maybe_model1.merge_in_updates(in_model)
                history_db.add(maybe_model)
                history_db.commit()

                return FoundationModelAddResponse(
                    model_id=maybe_model1.id,
                    just_created=False,
                )

        new_model = FoundationModelRecordOrm(
            **in_model.model_dump(),
        )
        history_db.add(new_model)
        history_db.commit()

        response.status_code = fastapi.status.HTTP_201_CREATED
        return FoundationModelAddResponse(
            model_id=new_model.id,
            just_created=True
        )

    @router_ish.get("/models/{id:int}")
    def get_model_config(
            id: int,
            history_db: HistoryDB = Depends(get_history_db),
    ):
        match_object = history_db.execute(
            select(FoundationModelRecordOrm)
            .filter_by(id=id)
        ).scalar_one_or_none()
        if match_object is None:
            raise HTTPException(400, "No matching object")

        return match_object
