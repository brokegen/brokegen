"""
Providers register themselves and handle any setup that matches.

For… complexity's sake, this is done as a JSON dict.
Current known providers generally have two things to look for: Type, and ID.

1. type: ollama / id: http://localhost:11434
2. type: llamafile / id: ~/Downloads/llava-v1.5-7b-q4.llamafile
"""
import logging
from abc import abstractmethod
from typing import TypeAlias, Callable, Awaitable

from providers.orm import ProviderLabel, ProviderRecord

logger = logging.getLogger(__name__)


class BaseProvider:
    @abstractmethod
    async def available(self) -> bool:
        raise NotImplementedError()

    @abstractmethod
    async def make_record(self) -> ProviderRecord:
        raise NotImplementedError()


ProviderFactory: TypeAlias = Callable[[ProviderLabel], Awaitable[BaseProvider | None]]
"""
Try start + start is a single combined function because Providers are expected to be low overhead.
In cases where we manage our own servers (llamafile, llama.cpp), we expect those Providers to quietly manage resources.
"""


class _Borg:
    _shared_state = {}

    def __init__(self):
        self.__dict__ = self._shared_state


class ProviderRegistry(_Borg):
    _factories: list[ProviderFactory]
    by_label: dict[ProviderLabel, BaseProvider]
    by_record: dict[ProviderRecord, BaseProvider]

    def __init__(self):
        _Borg.__init__(self)

        if not hasattr(self, '_factories'):
            self._factories = []
        if not hasattr(self, 'by_config'):
            self.by_label = {}
        if not hasattr(self, 'by_record'):
            self.by_record = {}

    def register_factory(
            self,
            try_make_fn: ProviderFactory,
    ) -> None:
        self._factories.append(try_make_fn)

    async def make(self, label: ProviderLabel) -> BaseProvider | None:
        for try_make_fn in self._factories:
            result = await try_make_fn(label)
            if result is not None:
                logger.info(f"ProviderRegistry.make succeeded: {label}")
                self.by_label[label] = result
                self.by_record[await result.make_record()] = result
                return result

        return None
