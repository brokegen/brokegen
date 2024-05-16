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
from fastapi import APIRouter, Depends, FastAPI, Request

from access.ratelimits import init_db as init_ratelimits_db, RatelimitsDB, get_db as get_ratelimits_db
from inference.embeddings.knowledge import get_knowledge, KnowledgeSingleton, get_knowledge_dependency
from inference.routes_langchain import do_transparent_rag
from history.ollama.forward_routes import forward_request, forward_request_nodetails


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
        root_logger.addHandler(colorlog_stdout)

        # https://github.com/tiangolo/fastapi/discussions/7457
        # Convert uvicorn logging to this format also
        logging.getLogger("uvicorn.access").handlers = [colorlog_stdout]

    except ImportError:
        logging.basicConfig()


# Early call, because I can't figure out why our outputs are hidden
reconfigure_loglevels()


@asynccontextmanager
async def lifespan_for_fastapi(app: FastAPI):
    def install_langchain_routes(app: FastAPI):
        ollama_forwarder = APIRouter()

        @ollama_forwarder.get("/ollama-proxy/{path}")
        @ollama_forwarder.head("/ollama-proxy/{path}")
        @ollama_forwarder.post("/ollama-proxy/{path}")
        async def do_proxy_get_post(
                request: Request,
                ratelimits_db: RatelimitsDB = Depends(get_ratelimits_db),
                knowledge: KnowledgeSingleton = Depends(get_knowledge_dependency),
        ):
            if request.url.path == "/ollama-proxy/api/generate":
                return await do_transparent_rag(request, knowledge)

            if (
                    request.method == 'HEAD'
                    or request.url.path == "/ollama-proxy/api/show"
            ):
                return await forward_request_nodetails(request, ratelimits_db)

            return await forward_request(request, ratelimits_db)

        app.include_router(ollama_forwarder)

    install_langchain_routes(app)
    yield


@asynccontextmanager
async def lifespan_logging(app: FastAPI):
    # Silence the very annoying logs
    logging.getLogger("httpcore.http11").setLevel(logging.INFO)
    logging.getLogger("httpcore.connection").setLevel(logging.INFO)
    logging.getLogger("httpx").setLevel(logging.INFO)
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("urllib3.connectionpool").setLevel(logging.WARNING)

    async with lifespan_for_fastapi(app):
        yield

    root_logger = logging.getLogger()
    root_logger.setLevel(logging.WARNING)
    root_logger.handlers = []


@click.command()
@click.option('--data-dir', default='data/',
              help='Filesystem directory to store/read data from')
@click.option('--bind-port', default=6634, help='uvicorn bind port')
@click.option('--log-level', default='DEBUG',
              type=click.Choice(['DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL'], case_sensitive=False),
              help='loglevel to pass to Python `logging`')
def run_proxy(data_dir, bind_port, log_level):
    numeric_log_level = getattr(logging, str(log_level).upper(), None)
    logging.getLogger().setLevel(level=numeric_log_level)

    import asyncio
    import uvicorn

    app: FastAPI = FastAPI(
        lifespan=lifespan_logging,
    )

    init_ratelimits_db(f"{data_dir}/ratelimits.db")
    get_knowledge().load_shards_from(data_dir)

    config = uvicorn.Config(app, port=bind_port, log_level="debug", reload=False, workers=1)
    server = uvicorn.Server(config)

    try:
        asyncio.run(server.serve())

    except KeyboardInterrupt:
        print("Caught KeyboardInterrupt, exiting gracefully")


if __name__ == "__main__":
    run_proxy()
