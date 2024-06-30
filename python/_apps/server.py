# https://pyinstaller.org/en/v6.6.0/common-issues-and-pitfalls.html#common-issues
if __name__ == '__main__':
    # Doubly needed when working with uvicorn, probably
    # https://github.com/encode/uvicorn/issues/939
    # https://pyinstaller.org/en/latest/common-issues-and-pitfalls.html
    import multiprocessing
    multiprocessing.freeze_support()

import asyncio
import logging
import os
import sqlite3
from contextlib import asynccontextmanager
from datetime import timezone, datetime
from typing import Annotated, Awaitable

import click
import starlette.responses
from fastapi import FastAPI, APIRouter, Query
from starlette.background import BackgroundTask
from starlette.exceptions import HTTPException
from starlette.requests import Request

import audit
import client
import client.database
import client_ollama
import inference.continuation_routes
import inference.prompting.superprompting
import providers.foundation_models
import providers.routes
import providers_registry
import providers_registry.ollama.forwarding_routes
import providers_registry.ollama.sequence_extend
import providers_registry.openai.lm_studio
from audit.http import get_db as get_audit_db
from audit.http_raw import SqlLoggingMiddleware
from providers.registry import ProviderRegistry
from retrieval.faiss.knowledge import get_knowledge

logger = logging.getLogger(__name__)


def reconfigure_loglevels(enable_colorlog: bool):
    root_logger = logging.getLogger()

    try:
        if not enable_colorlog:
            raise ImportError

        import colorlog
        from colorlog import ColoredFormatter

        LOGFORMAT = "  %(log_color)s%(levelname)-8s%(reset)s | %(log_color)s%(message)s%(reset)s"
        formatter = ColoredFormatter(LOGFORMAT)

        colorlog_stdout = logging.StreamHandler()
        colorlog_stdout.setLevel(logging.DEBUG)
        colorlog_stdout.setFormatter(formatter)
        root_logger.handlers = [colorlog_stdout]

        # https://github.com/tiangolo/fastapi/discussions/7457
        # Convert uvicorn logging to this format also
        logging.getLogger("uvicorn.access").handlers = [colorlog_stdout]

    except ImportError:
        logging.basicConfig()


@asynccontextmanager
async def lifespan_logging(app: FastAPI):
    # Silence the very annoying logs
    logging.getLogger("httpcore.http11").setLevel(logging.INFO)
    logging.getLogger("httpcore.connection").setLevel(logging.INFO)
    logging.getLogger("httpx").setLevel(logging.INFO)
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("urllib3.connectionpool").setLevel(logging.WARNING)

    yield

    root_logger = logging.getLogger()
    root_logger.setLevel(logging.WARNING)
    root_logger.handlers = []


@asynccontextmanager
async def init_app(app: FastAPI):
    # DEBUG: Keep providers loaded at startup
    registry = ProviderRegistry()
    discoverers: list[Awaitable[None]] = [
        factory.discover(provider_type=None, registry=registry)
        for factory in registry.factories
    ]
    for done in asyncio.as_completed(discoverers):
        _ = await done

    async with lifespan_logging(app):
        yield


@click.command()
@click.option('--data-dir', default='data/', show_default=True,
              help='Filesystem directory to store/read data from',
              type=click.Path(exists=True, writable=True, file_okay=False))
@click.option('--bind-host', default="127.0.0.1", show_default=True,
              help='uvicorn bind host')
@click.option('--bind-port', default=6635, show_default=True,
              help='uvicorn bind port',
              type=click.IntRange(1, 65535))
@click.option('--log-level', default='DEBUG', show_default=True,
              help='loglevel to pass to Python `logging`',
              type=click.Choice(['DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL'], case_sensitive=False))
@click.option('--enable-colorlog', default=False, show_default=True, type=click.BOOL)
@click.option('--trace-sqlalchemy', default=False, show_default=True, type=click.BOOL)
@click.option('--trace-fastapi-http', default=True, show_default=True,
              help='Record FastAPI ingress/egress, at the HTTP request/response level',
              type=click.BOOL)
@click.option('--print-uvicorn-access-log', default=True, show_default=True,
              help='Print all HTTP requests/response codes',
              type=click.BOOL)
@click.option('--force-ollama-rag', default=False, show_default=True,
              help='Load FAISS files from --data-dir, and apply them to any ollama-proxy /api/chat calls',
              type=click.BOOL)
@click.option('--install-terminate-endpoint', default=False, show_default=True,
              help='Add /terminate endpoint that will halt the server. '
                   '(Sometimes needed due to how PyInstaller or Swift handle processes.)',
              type=click.BOOL)
def run_proxy(
        data_dir,
        bind_host,
        bind_port,
        log_level,
        enable_colorlog: bool,
        trace_sqlalchemy: bool,
        trace_fastapi_http: bool,
        print_uvicorn_access_log: bool,
        force_ollama_rag: bool,
        install_terminate_endpoint: bool,
):
    numeric_log_level = getattr(logging, str(log_level).upper(), None)
    logging.getLogger().setLevel(level=numeric_log_level)

    if enable_colorlog:
        reconfigure_loglevels(enable_colorlog)

    import asyncio
    import uvicorn

    app: FastAPI = FastAPI(
        lifespan=init_app,
    )

    if trace_sqlalchemy:
        logging.getLogger('sqlalchemy.engine').setLevel(logging.INFO)

    try:
        audit.http.init_db(f"{data_dir}/audit.db")
        client.database.load_db_models(f"{data_dir}/requests-history.db")
        inference.dspy.database.load_db_models(f"{data_dir}/prompting.db")

    except sqlite3.OperationalError:
        if not os.path.exists(data_dir):
            logger.fatal(f"Directory does not exist: {data_dir=}")
        else:
            logger.exception(f"Failed to initialize app databases")
        return

    if trace_fastapi_http:
        app.add_middleware(
            SqlLoggingMiddleware,
            audit_db=next(get_audit_db()),
        )

    @app.head("/")
    def head_response():
        """
        TODO: This should technically apply to every GET route, but we don't have much of a use case yet.

        I suppose it could be done/used for API discovery.
        """
        return starlette.responses.Response(status_code=200)

    @app.on_event('shutdown')
    def shutdown_event():
        logger.error(f"Detected FastAPI \"shutdown\" event")

    expecting_eventloop_stop = False

    async def exit_app(delay: float) -> None:
        nonlocal expecting_eventloop_stop
        await asyncio.sleep(delay)
        expecting_eventloop_stop = True
        loop = asyncio.get_running_loop()
        loop.stop()

    @app.exception_handler(HTTPException)
    async def http_exception_handler(
            request: starlette.requests.Request,
            exc,
    ):
        """
        NB Installing this causes the app to exit on any HTTP exceptions!
        """
        return starlette.responses.PlainTextResponse(
            str(exc.detail),
            status_code=exc.status_code,
            background=BackgroundTask(exit_app),
        )

    if install_terminate_endpoint:
        terminate_router = APIRouter()

        @terminate_router.put("/terminate")
        async def terminate_app(
                delay: Annotated[float, Query()] = 1.0,
        ):
            async def exit_task() -> None:
                return await exit_app(delay)

            return starlette.responses.JSONResponse(
                {
                    "status": f"exiting in {delay} seconds",
                    "timestamp": datetime.now(tz=timezone.utc).isoformat() + "Z",
                },
                background=BackgroundTask(exit_task),
            )

        app.include_router(terminate_router)

    (
        ProviderRegistry()
        .register_factory(providers_registry.echo.registry.EchoProviderFactory())
        .register_factory(providers_registry.openai.lm_studio.LMStudioFactory())
        .register_factory(providers_registry.llamafile.registry.LlamafileFactory([data_dir]))
        .register_factory(providers_registry.ollama.registry.ExternalOllamaFactory())
        .register_factory(providers_registry.lcp.factory.LlamaCppProviderFactory([data_dir]))
    )

    # Ollama proxy & emulation
    providers_registry.ollama.forwarding_routes.install_forwards(app, force_ollama_rag)
    client_ollama.emulate.install_forwards(app)

    # Direct test points, only used in Swagger test UI
    providers_registry.llamafile.direct_routes.install_test_points(app)
    inference.prompting.superprompting.install_routes(app, data_dir)

    # brokegen-specific endpoints
    providers.routes.install_routes(app)
    providers.foundation_models.routes.install_routes(app)
    inference.autonaming.routes.install_routes(app)
    inference.continuation_routes.install_routes(app)
    client.install_routes(app)

    providers_registry.ollama.sequence_extend.install_routes(app)

    get_knowledge().load_shards_from(None)
    get_knowledge().queue_data_dir(data_dir)

    config = uvicorn.Config(
        app,
        host=bind_host,
        port=bind_port,
        log_level="debug",
        access_log=print_uvicorn_access_log,
        reload=False,
        workers=4,
    )
    server = uvicorn.Server(config)

    try:
        asyncio.run(server.serve())

    except KeyboardInterrupt:
        print("Caught KeyboardInterrupt, exiting gracefully")

    except RuntimeError as e:
        if not expecting_eventloop_stop:
            logger.fatal(f"Stopped: {e}")


if __name__ == "__main__":
    run_proxy(max_content_width=192)
