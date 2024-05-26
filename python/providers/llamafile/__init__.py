import logging
import os
import subprocess
from datetime import datetime, timezone
from typing import Union

import httpx
import orjson
from sqlalchemy import select

from providers._util import local_provider_identifiers, local_fetch_machine_info
from providers.database import ProviderRecordOrm, HistoryDB, get_db
from providers.registry import ProviderConfig, ProviderRegistry, BaseProvider, ProviderRecord

logger = logging.getLogger(__name__)


class LlamafileProvider(BaseProvider):
    """
    Providers are expected to be extremely lightweight, so we have an extra "launch()" function that actually starts.

    TODO: Make instances share process interactions, which probably implies Borg pattern.
    """
    filename: str
    server_process: subprocess.Popen | None = None
    server_process_cmdline: str
    server_comms: httpx.AsyncClient

    def __init__(
            self,
            filename: str,
            target_host: str = "127.0.0.1",
            target_port: str = "1822",
    ):
        self.filename = filename
        self.server_process_cmdline = (
            f"{filename} --server --nobrowser "
            f"--port {target_port} --host {target_host}"
        )
        self.server_comms = httpx.AsyncClient(
            base_url=f"http://{target_host}:{target_port}",
            http2=True,
            proxy=None,
            cert=None,
            timeout=httpx.Timeout(2.0, read=None),
            max_redirects=0,
            follow_redirects=False,
        )

    def launch(self):
        self.server_process = subprocess.Popen(
            self.server_process_cmdline,
            shell=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
        )

    async def available(self) -> bool:
        ping1 = self.server_comms.build_request(
            method='HEAD',
            url='/',
        )
        await self.server_comms.send(ping1)
        return True

    async def make_record(self) -> ProviderRecord:
        history_db: HistoryDB = next(get_db())

        provider_identifiers_dict = {
            "name": "llamafile",
            "endpoint": self.filename,
        }
        provider_identifiers_dict.update(local_provider_identifiers())
        provider_identifiers = orjson.dumps(provider_identifiers_dict, option=orjson.OPT_SORT_KEYS)

        # Check for existing matches
        maybe_provider = history_db.execute(
            select(ProviderRecordOrm)
            .where(ProviderRecordOrm.identifiers == provider_identifiers)
        ).scalar_one_or_none()
        if maybe_provider is not None:
            return ProviderRecord.from_orm(maybe_provider)

        new_provider = ProviderRecordOrm(
            identifiers=provider_identifiers,
            created_at=datetime.now(tz=timezone.utc),
            machine_info=await local_fetch_machine_info(),
        )
        history_db.add(new_provider)
        history_db.commit()

        return ProviderRecord.from_orm(new_provider)

    @staticmethod
    def from_filename(filename: str) -> Union['LlamafileProvider', None]:
        try:
            # Llamafiles need to be run as shell, because they're not-recognizable-format-y
            llamafile_test = subprocess.Popen(
                f"{filename} --version",
                shell=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.STDOUT,
            )
            llamafile_test.wait(5.0)
            llamafile_test.terminate()
            if llamafile_test.returncode != 0:
                logger.warning(f"{filename} failed: {llamafile_test.returncode=}")
                return None

        except OSError as e:
            logger.warning(f"{filename} failed: {e}")
            return None

        except subprocess.CalledProcessError as e:
            logger.warning(f"{filename} failed: {llamafile_test.stderr or e}")
            return None

        return LlamafileProvider(filename)


async def discover_in(*search_paths: str):
    async def factory(config: ProviderConfig) -> LlamafileProvider | None:
        if config.type != 'llamafile':
            return None

        if not os.path.exists(config.id):
            return None

        return LlamafileProvider.from_filename(config.id)

    registry = ProviderRegistry()
    registry.register_factory(factory)

    def _generate_filenames():
        for rootpath in search_paths:
            logger.debug(f"LlamafileProvider: checking dir {os.path.abspath(rootpath)}")
            for dirpath, _, filenames in os.walk(rootpath):
                for file in filenames:
                    if file[-10:] != '.llamafile':
                        continue

                    yield os.path.abspath(os.path.join(rootpath, file))

    for file in _generate_filenames():
        await registry.make(ProviderConfig(type="llamafile", id=file))
