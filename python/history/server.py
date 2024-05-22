# https://pyinstaller.org/en/v6.6.0/common-issues-and-pitfalls.html#common-issues
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
from fastapi import FastAPI

import audit
import history
import history.ollama
from audit.http import get_db as get_audit_db
from audit.http_raw import SqlLoggingMiddleware
from inference.embeddings.knowledge import get_knowledge

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
@click.option('--bind-port', default=6635, help='uvicorn bind port')
@click.option('--log-level', default='DEBUG',
              type=click.Choice(['DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL'], case_sensitive=False),
              help='loglevel to pass to Python `logging`')
@click.option('--enable-rag', default=False,
              help='Load FAISS files from --data-dir, and apply them to any /api/chat calls')
def run_proxy(data_dir, bind_port, log_level, enable_rag):
    numeric_log_level = getattr(logging, str(log_level).upper(), None)
    logging.getLogger().setLevel(level=numeric_log_level)

    import asyncio
    import uvicorn

    app: FastAPI = FastAPI(
        lifespan=lifespan_logging,
    )

    try:
        audit.http.init_db(f"{data_dir}/audit.db")
        history.shared.database.load_models(f"{data_dir}/requests-history.db")

    except sqlite3.OperationalError:
        if not os.path.exists(data_dir):
            logger.fatal(f"Directory does not exist: {data_dir=}")
        else:
            logger.exception(f"Failed to initialize app databases")
        return

    history.ollama.install_forwards(app, enable_rag)
    history.ollama.install_test_points(app)
    history.chat.routes.install_routes(app)
    history.shared.routes.install_routes(app)

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
