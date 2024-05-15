import logging

from starlette.requests import Request

from access.ratelimits import RatelimitsDB
from history.database import HistoryDB
from history.ollama.forward_routes import forward_request

logger = logging.getLogger(__name__)


async def do_proxy_generate(
        request: Request,
        history_db: HistoryDB,
        ratelimits_db: RatelimitsDB,
):
    logger.info(f"Intercepted a generate request: {request}")
    return await forward_request(request, ratelimits_db)
