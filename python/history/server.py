# https://pyinstaller.org/en/v6.6.0/common-issues-and-pitfalls.html#common-issues
from history.ollama.model_routes import do_list_available_models

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
from typing import cast

import click
import starlette.responses
from fastapi import FastAPI, HTTPException, Depends

import audit
import history
import history.ollama
import providers.ollama
from audit.http import get_db as get_audit_db, AuditDB
from audit.http_raw import SqlLoggingMiddleware
from inference.embeddings.knowledge import get_knowledge
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.orm import ProviderLabel
from providers.registry import ProviderRegistry

logger = logging.getLogger(__name__)


def reconfigure_loglevels():
    root_logger = logging.getLogger()

    try:
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


# Early call, because I can't figure out why our outputs are hidden
reconfigure_loglevels()


@asynccontextmanager
async def lifespan_logging(app: FastAPI):
    reconfigure_loglevels()

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
@click.option('--data-dir', default='data/',
              help='Filesystem directory to store/read data from',
              type=click.Path(exists=True, writable=True, file_okay=False))
@click.option('--bind-port', default=6635, type=click.IntRange(0, 65535),
              help='uvicorn bind port')
@click.option('--log-level', default='DEBUG',
              type=click.Choice(['DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL'], case_sensitive=False),
              help='loglevel to pass to Python `logging`')
@click.option('--trace-sqlalchemy', default=False, type=click.BOOL)
@click.option('--trace-fastapi', default=True, type=click.BOOL)
@click.option('--enable-rag', default=False, type=click.BOOL,
              help='Load FAISS files from --data-dir, and apply them to any /api/chat calls')
def run_proxy(
        data_dir,
        bind_port,
        log_level,
        trace_sqlalchemy: bool,
        trace_fastapi: bool,
        enable_rag,
):
    numeric_log_level = getattr(logging, str(log_level).upper(), None)
    logging.getLogger().setLevel(level=numeric_log_level)

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

    if trace_fastapi:
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

    @app.get("/models/available")
    async def list_available_models(
            provider: ProviderLabel = ProviderLabel(
                type="ollama",
                id="http://localhost:11434",
            ),
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
    ):
        ollama = ProviderRegistry().by_label[provider]
        if not isinstance(ollama, providers.ollama.OllamaProvider):
            raise HTTPException(501, "Only ollama is supported")

        return await do_list_available_models(
            cast(providers.ollama.OllamaProvider, ollama),
            history_db,
            audit_db,
        )

    asyncio.run(providers.ollama.discover_servers())
    asyncio.run(providers.llamafile.discover_in('dist'))

    history.ollama.install_forwards(app, enable_rag)
    history.ollama.install_test_points(app)
    history.chat.routes_message.install_routes(app)
    history.chat.install_routes(app)
    providers.inference_models.routes.install_routes(app)

    if enable_rag:
        get_knowledge().load_shards_from(data_dir)
    else:
        get_knowledge().load_shards_from(None)

    config = uvicorn.Config(app, port=bind_port, log_level="debug", reload=False, workers=1)
    server = uvicorn.Server(config)

    try:
        asyncio.run(server.serve())

    except KeyboardInterrupt:
        print("Caught KeyboardInterrupt, exiting gracefully")


if __name__ == "__main__":
    run_proxy()
