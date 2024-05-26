import logging
import platform
import subprocess
import uuid
from datetime import datetime, timezone
from typing import TypeAlias

import httpx
import orjson
from sqlalchemy import select

from providers.database import HistoryDB, ProviderRecord, get_db
from providers.registry import ProviderConfig, ProviderRegistry, BaseProvider

logger = logging.getLogger(__name__)

SortedExecutorConfig: TypeAlias = ProviderRecord

_real_ollama_client = httpx.AsyncClient(
    base_url="http://localhost:11434",
    http2=True,
    proxy=None,
    cert=None,
    timeout=httpx.Timeout(2.0, read=None),
    max_redirects=0,
    follow_redirects=False,
)


class OllamaProvider(BaseProvider):
    base_url: str
    client: httpx.AsyncClient

    def __init__(self, base_url: str):
        self.base_url = base_url
        self.client = httpx.AsyncClient(
            base_url=self.base_url,
            http2=True,
            proxy=None,
            cert=None,
            timeout=httpx.Timeout(2.0, read=None),
            max_redirects=0,
            follow_redirects=False,
        )

        logger.info(f"OllamaProvider: {base_url}")

    async def available(self) -> bool:
        """Ping endpoint to make sure it's up"""
        ping1 = self.client.build_request(
            method='HEAD',
            url='/',
        )
        response1 = await self.client.send(ping1)
        if response1.status_code != 200:
            logger.debug(f"Ping {self.base_url}: {response1.status_code=}")
            return False

        return True

    def build_executor_record(self):
        history_db = next(get_db())

        executor_info = {
            'name': "ollama",
            'endpoint': self.base_url,
        }
        executor_info.update(fetch_system_info())
        executor_info = orjson.loads(orjson.dumps(
            orjson.loads(executor_info.items()),
            option=orjson.OPT_SORT_KEYS,
        ))

        maybe_executor = history_db.execute(
            select(ProviderRecord)
            .where(ProviderRecord.provider_identifiers == executor_info)
        ).scalar_one_or_none()
        if maybe_executor is not None:
            return maybe_executor

        new_executor = ProviderRecord(
            executor_info=executor_info,
            created_at=datetime.now(tz=timezone.utc),
        )
        history_db.add(new_executor)
        history_db.commit()

        return new_executor


def fetch_system_info(
        include_personal_information: bool = True,
):
    if include_personal_information:
        system_profiler = subprocess.Popen(
            ["/usr/sbin/system_profiler", "-timeout", "5", "-json", "SPHardwareDataType"]
        )
    else:
        system_profiler = subprocess.Popen(
            *"/usr/sbin/system_profiler -timeout 5 -json -detailLevel mini SPHardwareDataType".split()
        )

    hardware_dict = orjson.loads(system_profiler.stdout.read())

    # If we somehow still don't have output, fall back to Python defaults
    # TODO: Add these to a standard "core" set of identifiers, the rest can be notes or whatever
    if not hardware_dict:
        hardware_dict["platform"] = platform.platform()

        # https://docs.python.org/3/library/uuid.html#uuid.getnode
        # This is based on the MAC address of a network interface on the host system; the important
        # thing is that the ProviderConfigRecord differs when the setup might give different results.
        hardware_dict["node_id"] = uuid.getnode()

    if include_personal_information:
        system_profiler1 = subprocess.Popen(
            ["/usr/sbin/system_profiler", "-timeout", "5", "-json", "SPSoftwareDataType"]
        )
    else:
        system_profiler1 = subprocess.Popen(
            ["/usr/sbin/system_profiler", "-timeout", "5", "-json", "-detailLevel", "mini", "SPSoftwareDataType"]
        )

    software_dict = dict(hardware_dict)
    software_dict.update(orjson.loads(system_profiler1.stdout.read()))
    del software_dict["SPSoftwareDataType"]["uptime"]

    return software_dict


async def discover_servers():
    async def factory(config: ProviderConfig) -> OllamaProvider | None:
        if config.type != 'ollama':
            return None

        maybe_provider = OllamaProvider(base_url=config.id)
        if not await maybe_provider.available():
            logger.info(f"OllamaProvider endpoint offline, skipping: {config.id}")
            return None

        return maybe_provider

    registry = ProviderRegistry()
    registry.register_factory(factory)

    await registry.make(ProviderConfig(type="ollama", id="http://localhost:11434"))


def build_executor_record(
        endpoint: str,
        do_commit: bool = True,
        history_db: HistoryDB | None = None,
) -> ProviderRecord:
    executor_singleton = OllamaExecutor()
    if endpoint != executor_singleton.ollama_base_url:
        logger.warning(f"Found `build_executor_record()` call with weird endpoint: {endpoint}")

    if not do_commit:
        logger.warning(f"Found a caller that wants {do_commit=}, ignoring")

    return executor_singleton.build_executor_record()
