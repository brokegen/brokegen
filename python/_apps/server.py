# https://pyinstaller.org/en/v6.6.0/common-issues-and-pitfalls.html#common-issues
import history.ollama.direct_routes
import history.ollama.forwarding_routes

if __name__ == '__main__':
    # Doubly needed when working with uvicorn, probably
    # https://github.com/encode/uvicorn/issues/939
    # https://pyinstaller.org/en/latest/common-issues-and-pitfalls.html
    import multiprocessing
    multiprocessing.freeze_support()

import logging
import os
import sqlite3
from contextlib import asynccontextmanager

import click
import starlette.responses
from fastapi import FastAPI

import audit
import history
import history.ollama
import providers.ollama
from audit.http import get_db as get_audit_db
from audit.http_raw import SqlLoggingMiddleware
from inference.embeddings.knowledge import get_knowledge

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
@click.option('--force-ollama-rag', default=False, show_default=True,
              help='Load FAISS files from --data-dir, and apply them to any ollama-proxy /api/chat calls',
              type=click.BOOL)
def run_proxy(
        data_dir,
        bind_host,
        bind_port,
        log_level,
        enable_colorlog: bool,
        trace_sqlalchemy: bool,
        trace_fastapi_http: bool,
        force_ollama_rag: bool,
):
    numeric_log_level = getattr(logging, str(log_level).upper(), None)
    logging.getLogger().setLevel(level=numeric_log_level)

    if enable_colorlog:
        reconfigure_loglevels(enable_colorlog)

    import asyncio
    import uvicorn

    app: FastAPI = FastAPI(
        lifespan=lifespan_logging,
    )

    if trace_sqlalchemy:
        logging.getLogger('sqlalchemy.engine').setLevel(logging.INFO)

    try:
        audit.http.init_db(f"{data_dir}/audit.db")
        providers.inference_models.database.load_db_models(f"{data_dir}/requests-history.db")

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

    asyncio.run(providers.openai.lm_studio.discover_lm_studio_servers())
    asyncio.run(providers.llamafile.discover_llamafiles_in('dist'))
    asyncio.run(providers.ollama.discover_ollama_servers())

    history.ollama.direct_routes.install_test_points(app)
    history.ollama.forwarding_routes.install_forwards(app, force_ollama_rag)
    history.chat.install_routes(app)
    providers.inference_models.routes.install_routes(app)
    providers.routes.install_routes(app)

    get_knowledge().load_shards_from(None)
    get_knowledge().queue_data_dir(data_dir)

    config = uvicorn.Config(
        app,
        host=bind_host,
        port=bind_port,
        log_level="debug",
        reload=False,
        workers=4,
    )
    server = uvicorn.Server(config)

    try:
        asyncio.run(server.serve())

    except KeyboardInterrupt:
        print("Caught KeyboardInterrupt, exiting gracefully")


if __name__ == "__main__":
    run_proxy(max_content_width=192)
