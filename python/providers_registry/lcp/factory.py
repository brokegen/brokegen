import logging
import os

from providers.orm import ProviderType, ProviderLabel
from providers.registry import BaseProvider, ProviderRegistry, ProviderFactory

logger = logging.getLogger(__name__)


class LlamaCppProviderFactory(ProviderFactory):
    search_dirs: list[str]

    def __init__(self, search_dirs: list[str] | None = None):
        self.search_dirs = search_dirs or []

    async def try_make(self, label: ProviderLabel) -> BaseProvider | None:
        if label.type != "lcp":
            return None

        if not os.path.exists(label.id):
            return None

        try:
            # We don't require the user to have llama-cpp-python installed,
            # because macOS installation usually takes some manual work.
            import llama_cpp
            from .provider import LlamaCppProvider

            return LlamaCppProvider(model_path=label.id)

        except ImportError:
            return None

    async def discover(
            self,
            provider_type: ProviderType | None,
            registry: ProviderRegistry,
    ) -> None:
        if provider_type is not None and provider_type != 'lcp':
            return

        def _generate_filenames():
            for rootpath in self.search_dirs:
                logger.debug(f"LlamaCppProviderFactory: checking dir {os.path.abspath(rootpath)}")
                for dirpath, _, filenames in os.walk(rootpath):
                    for file in filenames:
                        if file[-5:] != '.gguf':
                            continue

                        yield os.path.abspath(os.path.join(rootpath, file))

        for file in _generate_filenames():
            label = ProviderLabel(type="lcp", id=file)
            await registry.try_make(label)
