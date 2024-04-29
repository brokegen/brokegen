import logging
from contextlib import asynccontextmanager
from typing import Any

import httpx
from fastapi import FastAPI, Request
from starlette.background import BackgroundTask
from starlette.responses import StreamingResponse

client = httpx.AsyncClient(
    base_url="http://localhost:11434",
    http2=True,
    proxy=None,
    timeout=None,
    max_redirects=0,
    follow_redirects=False,
)
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logging.getLogger('hypercorn.error').disabled = True
    logging.basicConfig()

    async def do_proxy(
            request: Request,
    ):
        """
        Implements a simple reverse proxy, as stream-y as possible

        https://github.com/tiangolo/fastapi/issues/1788#issuecomment-1320916419
        """
        logger.debug(f"/ollama-proxy: {request.url.path}")

        url = httpx.URL(path=request.url.path.removeprefix("/ollama-proxy"),
                        query=request.url.query.encode("utf-8"))
        rp_req = client.build_request(request.method,
                                      url,
                                      headers=request.headers.raw,
                                      content=request.stream())
        rp_resp = await client.send(rp_req, stream=True)
        return StreamingResponse(
            rp_resp.aiter_raw(),
            status_code=rp_resp.status_code,
            headers=rp_resp.headers,
            background=BackgroundTask(rp_resp.aclose),
        )

    app.add_route("/ollama-proxy/{path:path}", do_proxy, ['GET', 'POST', 'HEAD'])

    yield


app: FastAPI = FastAPI(lifespan=lifespan)


if __name__ == "__main__":
    from hypercorn.config import Config
    config = Config()
    config.bind = ['0.0.0.0:9749']
    config.loglevel = 'debug'

    import asyncio
    from hypercorn.asyncio import serve

    asyncio.run(serve(app, config))
