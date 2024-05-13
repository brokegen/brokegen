# https://pyinstaller.org/en/v6.6.0/common-issues-and-pitfalls.html#common-issues
from inference.routes import install_proxy_routes

if __name__ == '__main__':
    # Doubly needed when working with uvicorn, probably
    # https://github.com/encode/uvicorn/issues/939
    # https://pyinstaller.org/en/latest/common-issues-and-pitfalls.html
    import multiprocessing

    multiprocessing.freeze_support()

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.encoders import jsonable_encoder
from starlette import status
from starlette.requests import Request
from starlette.responses import JSONResponse


@asynccontextmanager
async def lifespan_for_fastapi(app: FastAPI):
    install_proxy_routes(app)
    yield


@asynccontextmanager
async def lifespan_logging(app: FastAPI):
    root_logger = logging.getLogger()
    root_logger.setLevel(logging.DEBUG)

    try:
        import colorlog
        from colorlog import ColoredFormatter

        LOGFORMAT = "  %(log_color)s%(levelname)-8s%(reset)s | %(log_color)s%(message)s%(reset)s"
        formatter = ColoredFormatter(LOGFORMAT)

        stream = logging.StreamHandler()
        stream.setLevel(logging.DEBUG)
        stream.setFormatter(formatter)
        root_logger.addHandler(stream)

    except ImportError:
        logging.basicConfig()

    # Silence the very annoying logs
    logging.getLogger("httpx").setLevel(logging.INFO)
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("urllib3.connectionpool").setLevel(logging.WARNING)

    async with lifespan_for_fastapi(app):
        yield

    root_logger.setLevel(logging.WARNING)
    root_logger.handlers = []


@asynccontextmanager
async def lifespan_generic(app: FastAPI):
    @app.exception_handler(Exception)
    async def print_exception_stacks(request: Request, exc):
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            content=jsonable_encoder({
                "detail"    : exc.errors(),  # optionally include the errors
                "body"      : exc.body,
                "custom msg": {"Your error message"}}),
        )

    async with lifespan_logging(app):
        yield


app: FastAPI = FastAPI(
    docs_url=None,
    redoc_url=None,
    lifespan=lifespan_generic,
    openapi_tags=[
        {"name": "Favorite"},
    ],
)

if __name__ == "__main__":
    import asyncio
    import uvicorn

    # TODO: Read config from sys.argv
    # NB Forget it, no multiprocess'd workers, I can't figure out what to do with them from within PyInstaller
    config = uvicorn.Config(app, port=6633, log_level="debug", reload=False, workers=1)
    server = uvicorn.Server(config)

    asyncio.run(server.serve())
