import logging

import httpx
from fastapi import APIRouter, Depends, FastAPI, Request

from access.ratelimits import RatelimitsDB
from access.ratelimits import get_db as get_ratelimits_db
from history.database import HistoryDB, get_db as get_history_db
from inference.routes import forward_request

_real_ollama_client = httpx.AsyncClient(
    base_url="http://localhost:11434",
    http2=True,
    proxy=None,
    cert=None,
    timeout=httpx.Timeout(2.0, read=None),
    max_redirects=0,
    follow_redirects=False,
)

logger = logging.getLogger(__name__)


async def do_api_show(
        original_request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
):
    pass


def install_forwards(app: FastAPI):
    ollama_forwarder = APIRouter()

    @ollama_forwarder.get("/ollama-proxy/{path:path}")
    @ollama_forwarder.head("/ollama-proxy/{path:path}")
    @ollama_forwarder.post("/ollama-proxy/{path:path}")
    async def do_proxy_get_post(
            request: Request,
            history_db: HistoryDB = Depends(get_history_db),
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        # if request.url.path == "/ollama-proxy/api/show":
        #     return await do_api_show(request, history_db, ratelimits_db)

        return await forward_request(request, ratelimits_db)

    app.include_router(ollama_forwarder)
