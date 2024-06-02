import copy
import logging
from dataclasses import dataclass
from enum import Enum
from typing import TypeAlias

import langchain_community
import langchain_core
from faiss import IndexFlatL2
from langchain_community.docstore import InMemoryDocstore
from langchain_community.embeddings import OllamaEmbeddings
from langchain_community.vectorstores import FAISS
from langchain_core.embeddings import Embeddings

logger = logging.getLogger(__name__)

VectorStoreShard: TypeAlias = langchain_community.vectorstores.FAISS
VectorStoreShardID: TypeAlias = str

VectorStoreUnified: TypeAlias = langchain_community.vectorstores.FAISS


@dataclass
class EmbedderConfigData:
    model_name: str
    dimensions: int

    def as_dir_prefix(self):
        return self.model_name.replace(':', '--')


class EmbedderConfig(Enum):
    nomic = EmbedderConfigData('nomic-embed-text:latest', 768)
    mxbai = EmbedderConfigData('mxbai-embed-large:latest', 1024)

    @property
    def model_name(self):
        return self.value.model_name

    @property
    def dimensions(self):
        return self.value.dimensions


class VectorStoreReadOnly:
    """
    Loads the .faiss/.pkl files written by langchain's FAISS module.

    Embeddings are tied to the specific model that was used for embedding.
    User queries can, however, be shrunk down to something useful for retrieving relevant documents.

    For now, just load every shard we can find into RAM (faiss-cpu IndexFlatL2).
    ("Shards" are used to make it easier to share data across systems, and for narrowing the
    search space for different applications.)
    """
    embedder: langchain_core.embeddings.Embeddings
    unified_vectordb: VectorStoreUnified

    def __init__(
            self,
            embedder_config: EmbedderConfig,
    ):
        self.embedder = OllamaEmbeddings(
            model=embedder_config.model_name,
        )

        self.unified_vectordb = FAISS(
            embedding_function=self.embedder,
            index=IndexFlatL2(embedder_config.dimensions),
            docstore=InMemoryDocstore(),
            index_to_docstore_id={},
        )
        "An in-memory vector store that includes the contents of any documents added or loaded"

    def _load_from(self, parent_dir: str, shard_id: VectorStoreShardID) -> VectorStoreShard | None:
        try:
            new_vectordb = FAISS.load_local(
                parent_dir,
                self.embedder,
                shard_id,
                allow_dangerous_deserialization=True)
            logger.info(f"Loaded {len(new_vectordb.index_to_docstore_id):_} embeddings "
                        f"from \"{parent_dir}\" / \"{shard_id}\"")
            return new_vectordb

        except RuntimeError:
            logger.info(f"Couldn't load \"{shard_id}\" from file, ignoring")
            return None

    def _copy_in(self, shard0: VectorStoreShard, destructive: bool = False):
        original_entries_count = len(self.unified_vectordb.index_to_docstore_id)

        # Manually detect duplicates… this is surely very slow.
        overlap = set(self.unified_vectordb.index_to_docstore_id.values()) \
            .intersection(shard0.index_to_docstore_id.values())

        # This copy depends on an implementation detail of `langchain_community.vectorstores.FAISS`:
        # the .merge_from() call destructively copies _only_ the index.
        if destructive:
            dead_shard = shard0
        else:
            dead_shard = FAISS(
                embedding_function=shard0.embedding_function,
                index=copy.deepcopy(shard0.index),
                docstore=shard0.docstore,
                index_to_docstore_id=shard0.index_to_docstore_id,
                relevance_score_fn=shard0.override_relevance_score_fn,
                normalize_L2=shard0._normalize_L2,
                distance_strategy=shard0.distance_strategy,
            )

        if overlap:
            logger.debug(f"Clearing {len(overlap)} potential embeddings overlaps from self.unified_vectordb")
            self.unified_vectordb.delete([*overlap])

        try:
            self.unified_vectordb.merge_from(dead_shard)
        except RuntimeError:
            logger.exception(f"Skipping merge for {dead_shard}")
            return

        new_entries_count = len(self.unified_vectordb.index_to_docstore_id)
        logger.debug(f"Merged {new_entries_count - original_entries_count:_} into main memory store"
                     f" => {new_entries_count:_} total entries")
