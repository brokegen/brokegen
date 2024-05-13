"""
Offline, standalone CLI that converts files into LLM input.

- sorts through files in a given directory

The updated contents can then be used by the main FastAPI endpoint to serve embeddings.
"""

# https://pyinstaller.org/en/v6.6.0/common-issues-and-pitfalls.html#common-issues
if __name__ == '__main__':
    import multiprocessing
    multiprocessing.freeze_support()

import logging
import multiprocessing
import os
import sys
from contextlib import asynccontextmanager

import pypandoc
from fastapi import FastAPI
from fastapi.encoders import jsonable_encoder
from fastapi.openapi.docs import (
    get_redoc_html,
    get_swagger_ui_html,
    get_swagger_ui_oauth2_redirect_html
)
from fastapi.staticfiles import StaticFiles
from starlette import status
from starlette.requests import Request
from starlette.responses import JSONResponse


@asynccontextmanager
async def lifespan_for_fastapi(app: FastAPI):
    app.mount("/static", StaticFiles(directory="static"), name="static")

    @app.get("/docs", include_in_schema=False)
    async def custom_swagger_ui_html():
        return get_swagger_ui_html(
            openapi_url=app.openapi_url,
            title=app.title + " - Swagger UI",
            oauth2_redirect_url=app.swagger_ui_oauth2_redirect_url,
            swagger_js_url="/static/swagger-ui-bundle.js",
            swagger_css_url="/static/swagger-ui.css",
            swagger_favicon_url="",
            swagger_ui_parameters={"tryItOutEnabled": True},
        )

    @app.get(app.swagger_ui_oauth2_redirect_url, include_in_schema=False)
    async def swagger_ui_redirect():
        return get_swagger_ui_oauth2_redirect_html()

    @app.get("/redoc", include_in_schema=False)
    async def redoc_html():
        return get_redoc_html(
            openapi_url=app.openapi_url,
            title=app.title + " - ReDoc",
            redoc_js_url="/static/redoc.standalone.js"
        )

    try:
        knowledge = get_knowledge()
        knowledge.load_faiss()

        app.include_router(viewer.retrieval.routes.router)
        viewer.retrieval.routes_inference.add_embedding(app)

    except ValueError as e:
        print("[WARN] Couldn't initialize viewer.retrieval, check connection to Ollama")
        print(e)

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

        # This is expected to reveal whether you're a "developer",
        # https://www.structlog.org/en/stable/logging-best-practices.html#pretty-printing-vs-structured-output
        root_logger.info(f"{sys.stderr.isatty()=}")

    except ImportError:
        logging.basicConfig()

    # Silence the very annoying ones
    logging.getLogger("chardet.charsetprober").setLevel(logging.INFO)
    logging.getLogger("chardet.universaldetector").setLevel(logging.INFO)
    logging.getLogger("hpack").setLevel(logging.WARNING)
    logging.getLogger("httpcore.http11").setLevel(logging.INFO)
    logging.getLogger("httpcore.connection").setLevel(logging.INFO)
    logging.getLogger("httpx").setLevel(logging.INFO)
    logging.getLogger("markdown_it.rules_block").setLevel(logging.INFO)
    logging.getLogger("PIL.Image").setLevel(logging.INFO)
    logging.getLogger("PIL.TiffImagePlugin").setLevel(logging.INFO)
    logging.getLogger("pypandoc").setLevel(logging.ERROR)
    logging.getLogger("pypdf").setLevel(logging.CRITICAL)
    logging.getLogger("unstructured").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("urllib3.connectionpool").setLevel(logging.WARNING)

    async with lifespan_for_fastapi(app):
        yield

    root_logger.setLevel(logging.WARNING)
    root_logger.handlers = []


@asynccontextmanager
async def lifespan_generic(app: FastAPI):
    # opt out of telemetry
    # https://github.com/Unstructured-IO/unstructured/issues/2549
    os.environ["SCARF_NO_ANALYTICS"] = "true"
    os.environ["DO_NOT_TRACK"] = "true"

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
    # This is set if we're running in some PyInstaller configs (--onefile, I think)
    if hasattr(sys, '_MEIPASS'):
        # Our configure script puts pandoc in the top-level directory, so go there
        os.environ.setdefault('PYPANDOC_PANDOC',
                              os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pandoc'))
        # pprint(list(os.walk(os.environ.get('PYPANDOC_PANDOC'))))
        # pprint(list(os.walk(sys._MEIPASS)))
        # Kick the tires on pypandoc, make sure it's working correctly
        pypandoc.get_pandoc_version()
        pypandoc.get_pandoc_path()
        pypandoc.get_pandoc_formats()
