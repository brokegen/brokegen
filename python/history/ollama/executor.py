import logging
import platform
import subprocess
import uuid
from datetime import datetime, timezone
from typing import TypeAlias

import httpx
import orjson
from sqlalchemy import select

from history.shared.database import HistoryDB, ExecutorConfigRecord, get_db
from history.shared.json import JSONDict

logger = logging.getLogger(__name__)

SortedExecutorConfig: TypeAlias = ExecutorConfigRecord

_real_ollama_client = httpx.AsyncClient(
    base_url="http://localhost:11434",
    http2=True,
    proxy=None,
    cert=None,
    timeout=httpx.Timeout(2.0, read=None),
    max_redirects=0,
    follow_redirects=False,
)


class _Borg:
    _shared_state = {}

    def __init__(self):
        self.__dict__ = self._shared_state


class OllamaExecutor(_Borg):
    ollama_base_url: str

    def __init__(self, base_url: str = "http://localhost:11434"):
        _Borg.__init__(self)

        if hasattr(self, 'ollama_base_url') and self.ollama_base_url != base_url:
            logger.warning(
                f"Not overwriting OllamaExecutor.ollama_base_url:\n"
                f"  requested \"{base_url}\", keeping \"{self.ollama_base_url}\""
            )

        self.ollama_base_url = base_url

    def build_executor_record(self):
        history_db = next(get_db())

        executor_info: JSONDict = {
            'name': "ollama",
            'endpoint': self.ollama_base_url,
        }
        executor_info.update(fetch_system_info())
        executor_info = orjson.loads(orjson.dumps(
            orjson.loads(executor_info.items()),
            option=orjson.OPT_SORT_KEYS,
        ))

        maybe_executor = history_db.execute(
            select(ExecutorConfigRecord)
            .where(ExecutorConfigRecord.executor_info == executor_info)
        ).scalar_one_or_none()
        if maybe_executor is not None:
            return maybe_executor

        new_executor = ExecutorConfigRecord(
            executor_info=executor_info,
            created_at=datetime.now(tz=timezone.utc),
        )
        history_db.add(new_executor)
        history_db.commit()

        return new_executor


def fetch_system_info(
        include_personal_information: bool = True,
) -> JSONDict:
    if include_personal_information:
        system_profiler = subprocess.Popen(
            ["/usr/sbin/system_profiler", "-timeout", "5", "-json", "SPHardwareDataType"]
        )
    else:
        system_profiler = subprocess.Popen(
            *"/usr/sbin/system_profiler -timeout 5 -json -detailLevel mini SPHardwareDataType".split()
        )

    hardware_dict: JSONDict = orjson.loads(system_profiler.stdout.read())

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


def build_executor_record(
        endpoint: str,
        do_commit: bool = True,
        history_db: HistoryDB | None = None,
) -> ExecutorConfigRecord:
    executor_singleton = OllamaExecutor()
    if endpoint != executor_singleton.ollama_base_url:
        logger.warning(f"Found `build_executor_record()` call with weird endpoint: {endpoint}")

    if not do_commit:
        logger.warning(f"Found a caller that wants {do_commit=}, ignoring")

    return executor_singleton.build_executor_record()
