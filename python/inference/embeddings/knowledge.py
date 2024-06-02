import asyncio
import logging
import os
import pprint
import threading
import tracemalloc
from typing import Generator, Dict, Coroutine

from _util.status import ServerStatusHolder, StatusContext
from inference.embeddings.vectorestore import VectorStoreReadOnly, EmbedderConfig, VectorStoreShardID, VectorStoreShard

logger = logging.getLogger(__name__)


class _Borg:
    _shared_state = {}

    def __init__(self):
        self.__dict__ = self._shared_state


class RAMEstimator:
    start_size: int

    def __init__(
            self,
            log_fn,
            desc: str,
            manage_tracemalloc_hooks: bool = False,
    ):
        self.log_fn = log_fn or print
        self.desc = desc
        self.manage_tracemalloc_hooks = manage_tracemalloc_hooks

    def __enter__(self):
        if self.manage_tracemalloc_hooks:
            tracemalloc.start()

        self.start_size, _ = tracemalloc.get_traced_memory()
        return self

    def __exit__(self, exc_type, exc_value, tb):
        end_size, _ = tracemalloc.get_traced_memory()
        self.log_fn(f"Memory size delta for {self.desc}: {end_size - self.start_size:_}")

        if self.manage_tracemalloc_hooks:
            tracemalloc.stop()


def _generate_filenames(rootpath: str):
    for dirpath, _, filenames in os.walk(rootpath, followlinks=True):
        for file in filenames:
            yield dirpath, file


def _generate_on_disk_shard_ids(rootpath: str):
    known_pkl = set()
    known_faiss = set()

    for path, filename in _generate_filenames(rootpath):
        if filename[-4:] == '.pkl':
            known_pkl.add((path, filename[:-4]))

        if filename[-6:] == '.faiss':
            known_faiss.add((path, filename[:-6]))

    known_valid = known_pkl.intersection(known_faiss)
    logger.info(f"Identified vectorstore shards {pprint.pformat(known_valid, width=256)}")
    yield from known_valid


class KnowledgeSingleton(_Borg):
    loaded_vectorstores: Dict[EmbedderConfig, VectorStoreReadOnly]
    data_dirs_queued: set[str]
    data_dirs_loaded: set[str]

    seen_threads: set
    """
    NB This assumes thread ID's are unique across processes.
    Which is good enough for me.
    """

    def __init__(self):
        _Borg.__init__(self)
        if not hasattr(self, 'loaded_vectorstores'):
            self.loaded_vectorstores = {}
        if not hasattr(self, 'data_dirs_queued'):
            self.data_dirs_queued = set()
        if not hasattr(self, 'data_dirs_loaded'):
            self.data_dirs_loaded = set()
        if not hasattr(self, 'seen_threads'):
            self.seen_threads = set()

        if threading.current_thread().ident not in self.seen_threads:
            self.seen_threads.add(threading.current_thread().ident)
            logger.info(
                f"Initializing {self} with process {os.getpid()} / thread {threading.current_thread().ident}")

    def queue_data_dir(self, data_dir: str):
        self.data_dirs_queued.add(data_dir)

    async def load_queued_data_dirs_scatter_gather(
            self,
            status_holder: ServerStatusHolder,
            force_reload: bool = False,
            embedder_config: EmbedderConfig = EmbedderConfig.nomic,
    ):
        store = self.loaded_vectorstores[embedder_config]
        shards_loaded = 0

        def shards_generator():
            for data_dir in self.data_dirs_queued:
                if force_reload or data_dir not in self.data_dirs_loaded:
                    yield from _generate_on_disk_shard_ids(data_dir)

        async def load_from(parent_dir: str, shard_id: VectorStoreShardID):
            return store._load_from(parent_dir, shard_id)

        with StatusContext("KnowledgeSingleton.load_queued_data_dirs()", status_holder):
            with RAMEstimator(logger.info, "KnowledgeSingleton.load_queued_data_dirs()"):
                shard_loaders: list[Coroutine[str, VectorStoreShardID, VectorStoreShard | None]] = [
                    load_from(parent_dir, shard_id)
                    for (parent_dir, shard_id)
                    in shards_generator()
                ]
                shards_total = len(shard_loaders)

                for shard_loader_done in asyncio.as_completed(shard_loaders):
                    earliest_result: VectorStoreShard | None = await shard_loader_done
                    shards_loaded += 1
                    status_holder.set(f"KnowledgeSingleton loaded {shards_loaded} of {shards_total}: {earliest_result}")
                    if earliest_result is not None:
                        store._copy_in(earliest_result, destructive=True)

    async def load_queued_data_dirs(
            self,
            status_holder: ServerStatusHolder,
            force_reload: bool = False,
            embedder_config: EmbedderConfig = EmbedderConfig.nomic,
    ):
        store = self.loaded_vectorstores[embedder_config]

        def shards_generator():
            for data_dir in self.data_dirs_queued:
                if force_reload or data_dir not in self.data_dirs_loaded:
                    yield from _generate_on_disk_shard_ids(data_dir)

        async def load_from(parent_dir: str, shard_id: VectorStoreShardID):
            return store._load_from(parent_dir, shard_id)

        with StatusContext("KnowledgeSingleton.load_queued_data_dirs()", status_holder):
            shards_generated = list(shards_generator())
            shards_total = len(shards_generated)

            for index, (parent_dir, shard_id) in enumerate(shards_generated):
                with RAMEstimator(logger.debug, shard_id):
                    status_holder.set(f"KnowledgeSingleton loading {index + 1} of {shards_total}: {shard_id}")
                    maybe_shard = await load_from(parent_dir, shard_id)
                    if maybe_shard is not None:
                        store._copy_in(maybe_shard, destructive=True)

    def load_shards_from(
            self,
            # None is a special value that just makes us create the structs we need in memory.
            data_dir: str | None,
            embedder_config: EmbedderConfig = EmbedderConfig.nomic,
    ):
        if embedder_config not in self.loaded_vectorstores:
            self.loaded_vectorstores[embedder_config] = VectorStoreReadOnly(embedder_config)

        if data_dir is not None:
            with RAMEstimator(logger.info, f"all shards in {data_dir}", manage_tracemalloc_hooks=True):
                for parent_dir, shard_id in _generate_on_disk_shard_ids(data_dir):
                    with RAMEstimator(logger.debug, shard_id):
                        shard = self.loaded_vectorstores[embedder_config]._load_from(parent_dir, shard_id)
                        if shard is not None:
                            self.loaded_vectorstores[embedder_config]._copy_in(shard, destructive=True)

            self.data_dirs_loaded.add(data_dir)

    def as_retriever(self, **kwargs):
        if len(self.loaded_vectorstores) > 1:
            raise NotImplementedError(f"We don't _actually_ support juggling multiple VectorStores yet")

        target_vectorstore: VectorStoreReadOnly = list(self.loaded_vectorstores.values())[0]
        return target_vectorstore.unified_vectordb.as_retriever(**kwargs)


def get_knowledge() -> KnowledgeSingleton:
    return KnowledgeSingleton()


def get_knowledge_dependency() -> Generator[KnowledgeSingleton, None, None]:
    yield get_knowledge()
