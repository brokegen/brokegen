import logging
import os

from providers.orm import ProviderType, ProviderLabel
from providers.registry import BaseProvider, ProviderRegistry, ProviderFactory

logger = logging.getLogger(__name__)


class LlamaCppProviderFactory(ProviderFactory):
    search_dirs: list[str]
    cache_dir: str | None
    max_loaded_models: int

    def __init__(
            self,
            search_dirs: list[str] | None = None,
            cache_dir: str | None = None,
            max_loaded_models: int = 1,
    ):
        self.search_dirs = search_dirs or []
        self.cache_dir = cache_dir
        self.max_loaded_models = max_loaded_models

    async def try_make_nocache(self, label: ProviderLabel) -> BaseProvider | None:
        if label.type != "lcp":
            return None

        if not os.path.exists(label.id):
            return None

        try:
            # We don't require the user to have llama-cpp-python installed,
            # because macOS installation usually takes some manual work.
            import llama_cpp
            from .provider import LlamaCppProvider

            new_provider: BaseProvider = LlamaCppProvider(
                search_dir=label.id,
                cache_dir=self.cache_dir,
                max_loaded_models=self.max_loaded_models,
            )

            if await new_provider.available():
                return new_provider
            else:
                return None

        except ImportError:
            return None

    async def discover(
            self,
            provider_type: ProviderType | None,
            registry: ProviderRegistry,
    ) -> None:
        if provider_type is not None and provider_type != 'lcp':
            return

        for search_dir in self.search_dirs:
            label = ProviderLabel(type="lcp", id=search_dir)
            await registry.try_make(label)
