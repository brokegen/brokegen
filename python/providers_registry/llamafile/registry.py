import asyncio
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

from _util.json import safe_get, JSONDict
from _util.typing import FoundationModelRecordID
from providers._util import local_provider_identifiers, local_fetch_machine_info
from client.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import FoundationModelRecord, FoundationModelAddRequest, \
    lookup_foundation_model_detailed, FoundationModelRecordOrm
from providers.orm import ProviderRecordOrm, ProviderLabel, ProviderRecord, ProviderType
from providers.registry import ProviderRegistry, BaseProvider, ProviderFactory

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
            # Set a 24 hour timeout when llamafile is talking to llama.cpp
            "--timeout 86400 "
            # Lowest context size is 4096 for LLaVA models, use that as lowest common denominator
            # TODO: We're gonna need per-model tuning and contexts, etc etc. And also limits-testing.
            "--embedding --parallel 2 --ctx-size 4096 "
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

    async def try_launch(self) -> None:
        """
        TODO: explicitly an externally launched llamafile process.
        """
        if self.server_process is not None:
            while not await self.available():
                await asyncio.sleep(5)

            return

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

    async def list_models(self) -> AsyncGenerator[FoundationModelRecord, None]:
        model_name = os.path.basename(self.filename)
        if model_name[-10:] == '.llamafile':
            model_name = model_name[:-10]

        model_identifiers = {
            "name": model_name,
            "size": os.path.getsize(self.filename),
            "hash-sha256": self.compute_hash(),
            "file-ctime": datetime.fromtimestamp(os.path.getctime(self.filename)).isoformat(),
            "file-mtime": datetime.fromtimestamp(os.path.getmtime(self.filename)).isoformat(),
        }

        # Read the parameters from the server
        await self.try_launch()

        model_props: JSONDict | None
        try:
            response = await self.server_comms.request(
                method="GET",
                url="/props",
            )
            model_props = response.json()

        except httpx.ConnectError:
            return

        access_time = datetime.now(tz=timezone.utc)
        model_in = FoundationModelAddRequest(
            human_id=model_name,
            first_seen_at=access_time,
            last_seen=access_time,
            provider_identifiers=(await self.make_record()).identifiers,
            model_identifiers=model_identifiers,
            combined_inference_parameters=model_props,
        )

        history_db: HistoryDB = next(get_history_db())

        maybe_model: FoundationModelRecordID | None = lookup_foundation_model_detailed(model_in, history_db)
        if maybe_model is not None:
            maybe_model.merge_in_updates(model_in)
            history_db.add(maybe_model)
            history_db.commit()

            yield FoundationModelRecord.from_orm(maybe_model)

        else:
            logger.info(f".llamafile constructed a new FoundationModelRecord: {model_in.model_dump_json()}")
            new_model = FoundationModelRecordOrm(**model_in.model_dump())
            history_db.add(new_model)
            history_db.commit()

            yield FoundationModelRecord.from_orm(new_model)

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


class LlamafileFactory(ProviderFactory):
    search_dirs: list[str]

    def __init__(self, search_dirs: list[str] | None = None):
        self.search_dirs = search_dirs or []

    async def try_make(self, label: ProviderLabel) -> LlamafileProvider | None:
        if label.type != 'llamafile':
            return None

        if not os.path.exists(label.id):
            return None

        return LlamafileProvider.from_filename(label.id)

    async def discover(self, provider_type: ProviderType | None, registry: ProviderRegistry) -> None:
        if provider_type is not None and provider_type != 'llamafile':
            return

        def _generate_filenames():
            for rootpath in self.search_dirs:
                logger.debug(f"LlamafileFactory: checking dir {os.path.abspath(rootpath)}")
                for dirpath, _, filenames in os.walk(rootpath, followlinks=True):
                    for file in filenames:
                        if file[-10:] != '.llamafile':
                            continue

                        yield os.path.abspath(os.path.join(dirpath, file))

        for file in _generate_filenames():
            label = ProviderLabel(type="llamafile", id=file)
            await registry.try_make(label)
