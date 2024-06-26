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
from fastapi import Depends, FastAPI, Request

from audit.http import init_db as init_audit_db, AuditDB, get_db as get_audit_db
from audit.http_raw import SqlLoggingMiddleware
from client_ollama.forward import forward_request, forward_request_nodetails


def install_proxy_routes(app: FastAPI, install_logging_middleware: bool):
    proxy_app = FastAPI()
    if install_logging_middleware:
        proxy_app.add_middleware(
            SqlLoggingMiddleware,
            audit_db=next(get_audit_db()),
        )

    @proxy_app.get("/{path:path}")
    @proxy_app.head("/{path:path}")
    @proxy_app.post("/{path:path}")
    async def do_proxy_all(
            request: Request,
            audit_db: AuditDB = Depends(get_audit_db),
    ):
        if request.method == 'HEAD':
            return await forward_request_nodetails(request, audit_db)

        if request.url.path == "/api/show":
            return await forward_request_nodetails(request, audit_db)

        return await forward_request(request, audit_db)

    app.mount("/ollama-proxy", proxy_app)


def try_install_timing_middleware(app: FastAPI):
    try:
        from timing_asgi import TimingMiddleware, TimingClient
        from timing_asgi.integrations import StarletteScopeToName
    except ImportError:
        print("Failed to import timing-asgi")
        return

    class PrintTimings(TimingClient):
        def timing(self, metric_name, timing, tags):
            print(metric_name, f"{timing * 1000:.3f} msec", tags)

    app.add_middleware(
        TimingMiddleware,
        client=PrintTimings(),
        metric_namer=StarletteScopeToName(prefix="simple-proxy", starlette_app=app)
    )


def try_install_logging_middleware(app: FastAPI):
    app.add_middleware(
        SqlLoggingMiddleware,
        audit_db=next(get_audit_db()),
    )


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

    yield

    root_logger.setLevel(logging.WARNING)
    root_logger.handlers = []


# TODO: Check how initialization affects early-startup logging, and whether we should move this into a function.
# Otherwise, this has to stay here so pytest can access it easily.
app: FastAPI = FastAPI(
    lifespan=lifespan_logging,
)


@click.command()
@click.option('--data-dir', default='data/', show_default=True,
              help='Filesystem directory to store/read data from',
              type=click.Path(exists=True, writable=True, file_okay=False))
@click.option('--bind-host', default="127.0.0.1", show_default=True,
              help='uvicorn bind host')
@click.option('--bind-port', default=6633, show_default=True,
              help='uvicorn bind port',
              type=click.IntRange(0, 65535))
@click.option(
    '--install-timing-middleware',
    default=False,
    show_default=True,
)
@click.option(
    '--install-logging-middleware',
    default=True,
    show_default=True,
)
def run_proxy(
        data_dir,
        bind_host,
        bind_port,
        install_timing_middleware: bool,
        install_logging_middleware: bool,
):
    import asyncio
    import uvicorn

    init_audit_db(f"{data_dir}/audit.db")
    install_proxy_routes(app, install_logging_middleware)
    if install_timing_middleware:
        try_install_timing_middleware(app)

    # NB Forget it, no multiprocess'd workers, I can't figure out what to do with them from within PyInstaller
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
    run_proxy()
