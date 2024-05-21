from http.client import HTTPException

import fastapi.routing
from fastapi import FastAPI, Depends
from pydantic import BaseModel, ConfigDict
from sqlalchemy import select

from history.shared.database import HistoryDB, get_db as get_history_db, ModelConfigRecord, ModelConfigID


class ModelIn(BaseModel):
    human_id: str
    static_model_info: dict


class ModelAddResponse(BaseModel):
    model_id: ModelConfigID
    just_created: bool

    # Disable Pydantic warning where `model_` prefixed items are reserved.
    # TODO: We should find a way to name/rename the fields on the fly.
    model_config = ConfigDict(
        protected_namespaces=(),
    )


def install_routes(app: FastAPI):
    router = fastapi.routing.APIRouter()

    @router.post(
        "/models",
        response_model=ModelAddResponse,
    )
    async def create_model(
            model: ModelIn,
            allow_duplicates: bool = False,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> ModelAddResponse:
        raise HTTPException(501, "Can't add new models yet")

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
