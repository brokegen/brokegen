import chromadb


class MyEmbeddingFunction(chromadb.EmbeddingFunction):
    def __call__(self, input: chromadb.Documents) -> chromadb.Embeddings:
        pass


class VectorStoreReadOnly:
    pass


class ChromaDBVectorStore(VectorStoreReadOnly):
    collection: chromadb.Collection

    def __init__(self, chroma_path="/data"):
        client = chromadb.PersistentClient(path=chroma_path)
        self.collection = client.get_or_create_collection(name="my_collection", embedding_function=MyEmbeddingFunction)

    def load_from_disk(self):
        pass
