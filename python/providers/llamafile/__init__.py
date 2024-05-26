import logging
import os
import subprocess
from typing import TypeAlias, Union

import httpx

from providers.database import ProviderRecord
from providers.registry import ProviderConfig, ProviderRegistry, BaseProvider

logger = logging.getLogger(__name__)

SortedExecutorConfig: TypeAlias = ProviderRecord


async def run_ingest(import_files_dir, import_suffix_filter, files_offset, files_count, data_dir):
    async with lifespan_generic(None):
        def _generate_filenames(rootpath: str):
            for dirpath, _, filenames in os.walk(rootpath):
                for file in filenames:
                    full_filepath = os.path.join(dirpath, file)
                    if import_suffix_filter:
                        n = len(import_suffix_filter)
                        if full_filepath[-n:] != import_suffix_filter:
                            continue

                    relative_dirpath = os.path.relpath(dirpath, rootpath)
                    if relative_dirpath:
                        yield os.path.join(relative_dirpath, file)
                    else:
                        yield file

        # TODO: Are we supposed to return an Iterable or Iterator?
        def sliced_filenames(rootpath: str):
            sorted_filenames = sorted(_generate_filenames(rootpath))
            logger.info(f"{rootpath}: Slicing files {files_offset} - {files_offset + files_count} "
                        f"of {len(sorted_filenames)} total")

            for index, full_filename in list(enumerate(sorted_filenames))[files_offset:files_offset + files_count]:
                yield f"#{index}", full_filename

        # TODO: We don't actually need to load anything, do we?
        knowledge = get_knowledge().load_shards_from(data_dir)
        return await ingest.filesystem.bulk_loader(
            sliced_filenames(import_files_dir),
            knowledge)


class LlamafileProvider(BaseProvider):
    real_server: subprocess.Popen
    client: httpx.AsyncClient

    def __init__(
            self,
            filename: str,
            target_host: str = "127.0.0.1",
            target_port: str = "1822",
    ):
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
