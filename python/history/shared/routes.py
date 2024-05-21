from http.client import HTTPException

import fastapi.routing
from fastapi import FastAPI, Depends
from sqlalchemy import select

from history.shared.database import HistoryDB, get_db as get_history_db, ModelConfigRecord


def install_routes(app: FastAPI):
    router = fastapi.routing.APIRouter()

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
