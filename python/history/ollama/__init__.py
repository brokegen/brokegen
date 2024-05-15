from fastapi import FastAPI, APIRouter, Depends
from starlette.requests import Request

from access.ratelimits import RatelimitsDB, get_db as get_ratelimits_db
from history.database import HistoryDB, get_db as get_history_db
from history.ollama.forward_routes import forward_request_nodetails, forward_request
from history.ollama.model_routes import do_api_tags, do_api_show


def install_forwards(app: FastAPI):
    ollama_forwarder = APIRouter()

    @ollama_forwarder.head("/ollama-proxy/{path:path}")
    async def do_proxy_get_post(
            request: Request,
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        """
        Don't even bother logging HEAD requests.
        """
        return await forward_request_nodetails(request, ratelimits_db)

    @ollama_forwarder.get("/ollama-proxy/{path:path}")
    @ollama_forwarder.post("/ollama-proxy/{path:path}")
    async def do_proxy_get_post(
            request: Request,
            history_db: HistoryDB = Depends(get_history_db),
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        if request.url.path == "/ollama-proxy/api/tags":
            return await do_api_tags(request, history_db, ratelimits_db)

        if request.url.path == "/ollama-proxy/api/show":
            return await do_api_show(request, history_db, ratelimits_db)

        return await forward_request(request, ratelimits_db)

    app.include_router(ollama_forwarder)
