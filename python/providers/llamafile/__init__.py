import functools
import hashlib
import logging
import os
import subprocess
from datetime import datetime, timezone
from typing import Union, AsyncGenerator

import httpx
import orjson
from sqlalchemy import select

from _util.json import safe_get
from providers._util import local_provider_identifiers, local_fetch_machine_info
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecord, InferenceModelAddRequest, \
    lookup_inference_model_detailed, InferenceModelRecordOrm
from providers.orm import ProviderRecordOrm, ProviderLabel, ProviderRecord
from providers.registry import ProviderRegistry, BaseProvider

logger = logging.getLogger(__name__)


class LlamafileProvider(BaseProvider):
    """
    llamafile API is based on a vendored llama.cpp/server, see https://github.com/Mozilla-Ocho/llamafile

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

    async def fetch_health(self) -> str:
        health_request = (self.server_comms.build_request(
            method='GET',
            url='/health',
            # https://github.com/encode/httpx/discussions/2959
            # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
            headers=[('Connection', 'close')],
        ))

        response = await self.server_comms.send(health_request)
        await response.aclose()

        return safe_get(response.json(), "status") or "[unknown]"

    async def available(self) -> bool:
        health_status = await self.fetch_health()
        if health_status != "ok":
            logger.error(f"{self.filename} not available, response returned: {health_status}")
            return False

        return True

    async def make_record(self) -> ProviderRecord:
        history_db: HistoryDB = next(get_history_db())

        provider_identifiers_dict = {
            "name": "llamafile",
            "endpoint": self.filename,
        }
        version_info = LlamafileProvider._version_info(self.filename)
        if version_info is not None:
            provider_identifiers_dict["version_info"] = version_info

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

    @functools.lru_cache
    def compute_hash(self) -> str:
        sha256_hasher = hashlib.sha256()
        with open(self.filename, 'rb') as f:
            while chunk := f.read(4096):
                sha256_hasher.update(chunk)

        return sha256_hasher.hexdigest()

    async def list_models(self) -> AsyncGenerator[InferenceModelRecord, None]:
        model_name = os.path.basename(self.filename)
        if model_name[-10:] == '.llamafile':
            model_name = model_name[:-10]

        model_identifiers = {
            "name": model_name,
            "size": os.path.getsize(self.filename),
            "hash-sha256": self.compute_hash(),
            "file-ctime": os.path.getctime(self.filename),
            "file-mtime": os.path.getmtime(self.filename)
        }

        access_time = datetime.now(tz=timezone.utc)
        model_in = InferenceModelAddRequest(
            human_id=model_name,
            first_seen_at=access_time,
            last_seen=access_time,
            provider_identifiers=(await self.make_record()).identifiers,
            model_identifiers=model_identifiers,
            combined_inference_parameters=None,
        )

        history_db: HistoryDB = next(get_history_db())

        maybe_model = lookup_inference_model_detailed(model_in, history_db)
        if maybe_model is not None:
            maybe_model.merge_in_updates(model_in)
            history_db.add(maybe_model)
            history_db.commit()

            yield InferenceModelRecord.from_orm(maybe_model)

        else:
            logger.info(f".llamafile constructed a new InferenceModelRecord: {model_in.model_dump_json()}")
            new_model = InferenceModelRecordOrm(**model_in.model_dump())
            history_db.add(new_model)
            history_db.commit()

            yield InferenceModelRecord.from_orm(new_model)

    @staticmethod
    def _version_info(filename: str) -> str | None:
        try:
            # Llamafiles need to be run as shell, because they're not-recognizable-format-y
            llamafile_test = subprocess.Popen(
                f"{filename} --version",
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            llamafile_test.wait(30.0)
            llamafile_test.terminate()
            if llamafile_test.returncode != 0:
                logger.warning(f"{filename} failed: {llamafile_test.returncode=}")
                return None

            if llamafile_test.stdout is None:
                return None

            stdout_bytes = llamafile_test.stdout.read()
            if stdout_bytes is None:
                return None

            return stdout_bytes.decode()

        except (OSError, subprocess.SubprocessError) as e:
            logger.warning(f"{filename} failed: {e}")
            return None

        except subprocess.CalledProcessError as e:
            logger.warning(f"{filename} failed: {llamafile_test.stderr or e}")
            return None

    @staticmethod
    def from_filename(filename: str) -> Union['LlamafileProvider', None]:
        version_info = LlamafileProvider._version_info(filename)
        if version_info is None:
            return None

        return LlamafileProvider(filename)


async def discover_llamafiles_in(*search_paths: str):
    async def factory(label: ProviderLabel) -> LlamafileProvider | None:
        if label.type != 'llamafile':
            return None

        if not os.path.exists(label.id):
            return None

        return LlamafileProvider.from_filename(label.id)

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
        await registry.make(ProviderLabel(type="llamafile", id=file))
