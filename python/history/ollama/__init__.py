import logging
from contextlib import contextmanager

from fastapi import FastAPI, APIRouter, Depends
from starlette.requests import Request

from access.ratelimits import RatelimitsDB, get_db as get_ratelimits_db
from history.database import HistoryDB, get_db as get_history_db
from history.ollama.chat_rag_routes import do_proxy_chat_rag, do_proxy_chat_norag
from history.ollama.chat_routes import do_proxy_generate
from history.ollama.forward_routes import forward_request_nodetails, forward_request, forward_request_nolog
from history.ollama.model_routes import do_api_tags, do_api_show
from inference.embeddings.knowledge import KnowledgeSingleton, get_knowledge_dependency


@contextmanager
def disable_info_logs(*logger_names):
    previous_levels = {}

    for name in logger_names:
        previous_levels[name] = logging.getLogger(name).level
        logging.getLogger(name).setLevel(max(previous_levels[name], logging.WARNING))

    try:
        yield

    finally:
        for name in logger_names:
            logging.getLogger(name).setLevel(previous_levels[name])


def install_forwards(app: FastAPI, enable_rag: bool):
    ollama_forwarder = APIRouter()

    @ollama_forwarder.post("/ollama-proxy/api/generate")
    async def proxy_generate(
            request: Request,
            history_db: HistoryDB = Depends(get_history_db),
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        return await do_proxy_generate(request, history_db, ratelimits_db)

    @ollama_forwarder.post("/ollama-proxy/api/chat")
    async def proxy_chat_rag(
            request: Request,
            history_db: HistoryDB = Depends(get_history_db),
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
            knowledge: KnowledgeSingleton = Depends(get_knowledge_dependency),
    ):
        if enable_rag:
            return await do_proxy_chat_rag(request, history_db, ratelimits_db, knowledge)
        else:
            return await do_proxy_chat_norag(request, history_db, ratelimits_db)

    # TODO: Using a router prefix breaks this, somehow
    @ollama_forwarder.head("/ollama-proxy/{ollama_head_path:path}")
    async def proxy_head(
            request: Request,
            ollama_head_path,
    ):
        return await forward_request_nolog(ollama_head_path, request)

    @ollama_forwarder.get("/ollama-proxy/{ollama_get_path:path}")
    @ollama_forwarder.post("/ollama-proxy/{ollama_post_path:path}")
    async def proxy_get_post(
            request: Request,
            ollama_get_path: str | None = None,
            ollama_post_path: str | None = None,
            history_db: HistoryDB = Depends(get_history_db),
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        if ollama_get_path == "api/tags":
            return await do_api_tags(request, history_db, ratelimits_db)

        if ollama_post_path == "api/show":
            # TODO: Remove this log inhibitor once we've switched to a client that doesn't spam /api/show on startup
            with disable_info_logs("httpx", "history.ollama.model_routes"):
                return await do_api_show(request, history_db, ratelimits_db)

        return await forward_request(request, ratelimits_db)

    app.include_router(ollama_forwarder)
