import logging
from datetime import timezone, datetime

import httpx
from fastapi import Depends, FastAPI, Request
from starlette.background import BackgroundTask
from starlette.responses import StreamingResponse

from access.ratelimits import RatelimitsDB, ApiAccess, ApiAccessWithResponse
from access.ratelimits import get_db as get_ratelimits_db

_real_ollama_client = httpx.AsyncClient(
    base_url="http://localhost:11434",
    http2=True,
    proxy=None,
    timeout=None,
    max_redirects=0,
    follow_redirects=False,
)

logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)


def install_proxy_routes(app: FastAPI):
    async def do_proxy(
            request: Request,
            ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
    ):
        """
        Implements a simple reverse proxy, as stream-y as possible

        https://github.com/tiangolo/fastapi/issues/1788#issuecomment-1320916419
        """
        urlpath_noprefix = request.url.path.removeprefix("/ollama-proxy")
        logger.debug(f"/ollama-proxy: {request.method} {urlpath_noprefix}")

        url = httpx.URL(path=urlpath_noprefix,
                        query=request.url.query.encode("utf-8"))
        rp_req = _real_ollama_client.build_request(request.method,
                                                   url,
                                                   headers=request.headers.raw,
                                                   content=request.stream())
        rp_resp = await _real_ollama_client.send(rp_req, stream=True)

        new_access = ApiAccessWithResponse(
            api_bucket=__name__,
            accessed_at=datetime.now(tz=timezone.utc),
            api_endpoint=urlpath_noprefix,
            request=rp_req,
            response=rp_resp,
        )
        ratelimits_db.add(new_access)
        ratelimits_db.commit()

        return StreamingResponse(
            rp_resp.aiter_raw(),
            status_code=rp_resp.status_code,
            headers=rp_resp.headers,
            background=BackgroundTask(rp_resp.aclose),
        )

    app.add_route("/ollama-proxy/{path:path}", do_proxy, ['GET', 'POST', 'HEAD'])
