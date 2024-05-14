import logging
import os
import threading
from typing import Generator, Dict

from embeddings.vectorestore import VectorStoreReadOnly, EmbedderConfig

logger = logging.getLogger(__name__)


class _Borg:
    _shared_state = {}

    def __init__(self):
        self.__dict__ = self._shared_state


class KnowledgeSingleton(_Borg):
    loaded_vectorstores: Dict[EmbedderConfig, VectorStoreReadOnly]
    seen_threads: set
    """
    NB This assumes thread ID's are unique across processes.
    Which is good enough for me.
    """

    def __init__(self):
        _Borg.__init__(self)
        if not hasattr(self, 'loaded_vectorstores'):
            self.loaded_vectorstores = {}
        if not hasattr(self, 'seen_threads'):
            self.seen_threads = set()

        if threading.current_thread().ident not in self.seen_threads:
            self.seen_threads.add(threading.current_thread().ident)
            logger.info(
                f"Initializing {self} with process {os.getpid()} / thread {threading.current_thread().ident}")

    def load_shards_from(
            self,
            data_dir: str,
            embedder_config: EmbedderConfig = EmbedderConfig.nomic,
    ):
        def _generate_filenames(rootpath: str):
            for dirpath, _, filenames in os.walk(rootpath, followlinks=True):
                for file in filenames:
                    yield dirpath, file

        def _generate_on_disk_shard_ids():
            known_pkl = set()
            known_faiss = set()

            for path, filename in _generate_filenames(data_dir):
                if filename[-4:] == '.pkl':
                    known_pkl.add((path, filename[:-4]))

                if filename[-6:] == '.faiss':
                    known_faiss.add((path, filename[:-6]))

            known_valid = known_pkl.intersection(known_faiss)
            logger.info(f"Identified vectorstore shards {known_valid=}")
            yield from known_valid

        if embedder_config not in self.loaded_vectorstores:
            self.loaded_vectorstores[embedder_config] = VectorStoreReadOnly(embedder_config)

        for parent_dir, shard_id in _generate_on_disk_shard_ids():
            shard = self.loaded_vectorstores[embedder_config]._load_from(parent_dir, shard_id)
            if shard is not None:
                self.loaded_vectorstores[embedder_config]._copy_in(shard, destructive=True)

    def as_retriever(self, **kwargs):
        if len(self.loaded_vectorstores) > 1:
            raise NotImplementedError(f"We don't _actually_ support juggling multiple VectorStores yet")

        target_vectorstore: VectorStoreReadOnly = list(self.loaded_vectorstores.values())[0]
        return target_vectorstore.unified_vectordb.as_retriever(**kwargs)


def get_knowledge() -> KnowledgeSingleton:
    return KnowledgeSingleton()


def get_knowledge_dependency() -> Generator[KnowledgeSingleton, None, None]:
    yield get_knowledge()
