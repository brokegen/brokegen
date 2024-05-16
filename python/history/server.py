# https://pyinstaller.org/en/v6.6.0/common-issues-and-pitfalls.html#common-issues
if __name__ == '__main__':
    # Doubly needed when working with uvicorn, probably
    # https://github.com/encode/uvicorn/issues/939
    # https://pyinstaller.org/en/latest/common-issues-and-pitfalls.html
    import multiprocessing

    multiprocessing.freeze_support()

import logging
from contextlib import asynccontextmanager

import click
from fastapi import FastAPI

import access.ratelimits
import history
import history.ollama
from inference.embeddings.knowledge import get_knowledge


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
@click.option('--data-dir', default='data', help='Filesystem directory to store/read data from')
@click.option('--bind-port', default=6635, help='uvicorn bind port')
@click.option('--log-level', default='INFO', help='loglevel to pass to Python `logging`')
@click.option('--enable-rag', default=False,
              help='Load FAISS files from --data-dir, and apply them to any /api/chat calls')
def run_proxy(data_dir, bind_port, log_level, enable_rag):
    numeric_log_level = getattr(logging, str(log_level).upper(), None)
    if not isinstance(numeric_log_level, int):
        print(f"Log level not recognized, ignoring: {log_level}")
        logging.getLogger().setLevel(level=logging.INFO)
    else:
        logging.getLogger().setLevel(level=numeric_log_level)

    import asyncio
    import uvicorn

    app: FastAPI = FastAPI(
        lifespan=lifespan_logging,
    )

    access.ratelimits.init_db(f"{data_dir}/ratelimits.db")
    history.database.init_db(f"{data_dir}/requests-history.db")
    history.ollama.install_forwards(app, enable_rag)

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
