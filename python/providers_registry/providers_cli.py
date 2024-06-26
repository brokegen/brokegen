# https://pyinstaller.org/en/v6.6.0/common-issues-and-pitfalls.html#common-issues
if __name__ == '__main__':
    # Doubly needed when working with uvicorn, probably
    # https://github.com/encode/uvicorn/issues/939
    # https://pyinstaller.org/en/latest/common-issues-and-pitfalls.html
    import multiprocessing

    multiprocessing.freeze_support()

import json
import logging
import os
import sqlite3
from contextlib import asynccontextmanager

import click
from fastapi import Depends, FastAPI, Request

import audit
import client
import providers_registry
from _util.json import DatetimeEncoder
from audit.http import AuditDB, get_db as get_audit_db
from audit.http_raw import SqlLoggingMiddleware
from client_ollama.forward import forward_request, forward_request_nodetails
from providers.orm import ProviderLabel, ProviderRecord
from providers.registry import ProviderRegistry, BaseProvider

logger = logging.getLogger(__name__)


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


async def amain(
        provider_type: str,
        provider_id_or_endpoint: str,
        registry: ProviderRegistry,
        data_dir: str = "data/",
):
    try:
        audit.http.init_db(f"{data_dir}/audit.db")
        client.database.load_db_models(f"{data_dir}/requests-history.db")

    except sqlite3.OperationalError:
        if not os.path.exists(data_dir):
            logger.fatal(f"Directory does not exist: {data_dir=}")
        else:
            logger.exception(f"Failed to initialize app databases")
        return

    (
        registry
        .register_factory(providers_registry.echo.registry.EchoProviderFactory())
        .register_factory(providers_registry.openai.lm_studio.LMStudioFactory())
        .register_factory(providers_registry.llamafile.registry.LlamafileFactory(['dist']))
        .register_factory(providers_registry.ollama.registry.ExternalOllamaFactory())
        .register_factory(providers_registry.lcp.factory.LlamaCppProviderFactory())
    )

    print(json.dumps(
        [repr(f) for f in registry.factories],
        indent=4,
    ))

    label = ProviderLabel(type=provider_type, id=provider_id_or_endpoint)
    provider: BaseProvider | None = await registry.try_make(label)
    if provider is None:
        return

    provider_record: ProviderRecord = await provider.make_record()
    print(json.dumps(
        provider_record.model_dump(),
        indent=4,
        cls=DatetimeEncoder,
    ))
    print(f"{await provider.available()=}")


@click.command()
@click.argument('provider-type', type=click.STRING)
@click.argument('provider-id-or-endpoint', type=click.STRING)
def main(
        provider_type: str,
        provider_id_or_endpoint: str,
):
    import asyncio

    try:
        asyncio.run(amain(
            provider_type,
            provider_id_or_endpoint,
            ProviderRegistry()
        ))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
