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

from audit.http import init_db as init_audit_db, AuditDB, get_db as get_audit_db
from history.ollama.forward_routes import forward_request, forward_request_nodetails


@asynccontextmanager
async def lifespan_for_fastapi(app: FastAPI):
    def install_proxy_routes(app: FastAPI):
        ollama_forwarder = APIRouter()

        @ollama_forwarder.get("/ollama-proxy/{path}")
        @ollama_forwarder.head("/ollama-proxy/{path}")
        @ollama_forwarder.post("/ollama-proxy/{path}")
        async def do_proxy_all(
                request: Request,
                audit_db: AuditDB = Depends(get_audit_db),
        ):
            if request.method == 'HEAD':
                return await forward_request_nodetails(request, audit_db)

            if request.url.path == "/ollama-proxy/api/show":
                return await forward_request_nodetails(request, audit_db)

            return await forward_request(request, audit_db)

        app.include_router(ollama_forwarder)

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

        colorlog_stdout = logging.StreamHandler()
        colorlog_stdout.setLevel(logging.DEBUG)
        colorlog_stdout.setFormatter(formatter)
        root_logger.addHandler(colorlog_stdout)

        # https://github.com/tiangolo/fastapi/discussions/7457
        # Convert uvicorn logging to this format also
        logging.getLogger("uvicorn.access").handlers = [colorlog_stdout]

    except ImportError:
        logging.basicConfig()

    # Silence the very annoying logs
    logging.getLogger("httpcore.http11").setLevel(logging.INFO)
    logging.getLogger("httpcore.connection").setLevel(logging.INFO)
    logging.getLogger("httpx").setLevel(logging.INFO)
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("urllib3.connectionpool").setLevel(logging.WARNING)

    async with lifespan_for_fastapi(app):
        yield

    root_logger.setLevel(logging.WARNING)
    root_logger.handlers = []


# TODO: Check how initialization affects early-startup logging, and whether we should move this into a function.
# Otherwise, this has to stay here so pytest can access it easily.
app: FastAPI = FastAPI(
    lifespan=lifespan_logging,
)


@click.command()
@click.option('--data-dir', default='data', help='Filesystem directory to store/read data from')
def run_proxy(data_dir):
    import asyncio
    import uvicorn

    init_audit_db(f"{data_dir}/audit.db")

    # NB Forget it, no multiprocess'd workers, I can't figure out what to do with them from within PyInstaller
    config = uvicorn.Config(app, port=6633, log_level="debug", reload=False, workers=1)
    server = uvicorn.Server(config)

    try:
        asyncio.run(server.serve())

    except KeyboardInterrupt:
        print("Caught KeyboardInterrupt, exiting gracefully")


if __name__ == "__main__":
    run_proxy()
