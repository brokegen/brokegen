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

            new_provider: BaseProvider = LlamaCppProvider(search_dir=label.id)
            if new_provider.available():
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
