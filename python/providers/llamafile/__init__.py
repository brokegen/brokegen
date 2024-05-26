import logging
import os
import subprocess
from datetime import datetime, timezone
from typing import TypeAlias, Union

import httpx
import orjson
from sqlalchemy import select

from providers._util import local_provider_identifiers, local_fetch_machine_info
from providers.database import ProviderRecordOrm, HistoryDB, get_db
from providers.registry import ProviderConfig, ProviderRegistry, BaseProvider, ProviderRecord

logger = logging.getLogger(__name__)

SortedExecutorConfig: TypeAlias = ProviderRecordOrm


class LlamafileProvider(BaseProvider):
    filename: str
    real_server: subprocess.Popen
    client: httpx.AsyncClient

    def __init__(
            self,
            filename: str,
            target_host: str = "127.0.0.1",
            target_port: str = "1822",
    ):
        self.filename = filename
        self.real_server = subprocess.Popen(
            f"{filename} --server --nobrowser "
            f"--port {target_port} --host {target_host}",
            shell=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
        )
        self.client = httpx.AsyncClient(
            base_url=f"http://{target_host}:{target_port}",
            http2=True,
            proxy=None,
            cert=None,
            timeout=httpx.Timeout(2.0, read=None),
            max_redirects=0,
            follow_redirects=False,
        )

    async def available(self) -> bool:
        ping1 = self.client.build_request(
            method='HEAD',
            url='/',
        )
        await self.client.send(ping1)
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
        maybe_executor = history_db.execute(
            select(ProviderRecordOrm)
            .where(ProviderRecordOrm.provider_identifiers == provider_identifiers)
        ).scalar_one_or_none()
        if maybe_executor is not None:
            return ProviderRecord.from_orm(maybe_executor)

        new_executor = ProviderRecordOrm(
            provider_identifiers=provider_identifiers,
            created_at=datetime.now(tz=timezone.utc),
            machine_info=await local_fetch_machine_info(),
        )
        history_db.add(new_executor)
        history_db.commit()

        return ProviderRecord.from_orm(new_executor)

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
        provider = await registry.make(ProviderConfig(type="llamafile", id=file))
        if provider:
            await provider.make_record()
