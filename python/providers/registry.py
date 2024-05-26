"""
Providers register themselves and handle any setup that matches.

For… complexity's sake, this is done as a JSON dict.
Current known providers generally have two things to look for: Type, and ID.

1. type: ollama / id: http://localhost:11434
2. type: llamafile / id: ~/Downloads/llava-v1.5-7b-q4.llamafile
"""
import logging
from abc import abstractmethod
from datetime import datetime
from typing import TypeAlias, Callable, Awaitable, Optional

from pydantic import BaseModel, ConfigDict

ProviderType: TypeAlias = str
ProviderID: TypeAlias = str

logger = logging.getLogger(__name__)


class ProviderConfig(BaseModel):
    type: ProviderType
    id: ProviderID


class ProviderRecord(BaseModel):
    provider_identifiers: str
    created_at: datetime

    machine_info: Optional[dict] = None
    human_info: Optional[str] = None

    model_config = ConfigDict(
        from_attributes=True,
    )


class BaseProvider:
    @abstractmethod
    async def available(self) -> bool:
        raise NotImplementedError()

    @abstractmethod
    async def make_record(self) -> ProviderRecord:
        raise NotImplementedError()


ProviderFactory: TypeAlias = Callable[[ProviderConfig], Awaitable[BaseProvider | None]]
"""
This is a single combined function because it shouldn't be much overhead to instantiate a Provider.

TODO: Actually, instantiating LlamafileProviders is really expensive.
So we split off launch into a separate step.
"""


class _Borg:
    _shared_state = {}

    def __init__(self):
        self.__dict__ = self._shared_state


class ProviderRegistry(_Borg):
    _factories: list[ProviderFactory]
    by_config: dict[ProviderConfig, BaseProvider]
    by_record: dict[ProviderRecord, BaseProvider]

    def __init__(self):
        _Borg.__init__(self)

        if not hasattr(self, 'registered_funcs'):
            self._factories = []

    def register_factory(
            self,
            try_make_fn: ProviderFactory,
    ) -> None:
        self._factories.append(try_make_fn)

    async def make(self, config: ProviderConfig) -> BaseProvider | None:
        for try_make_fn in self._factories:
            result = await try_make_fn(config)
            if result is not None:
                logger.info(f"ProviderRegistry.make succeeded: {config}")
                self.by_config[config] = result
                self.by_record[await result.make_record()] = result
                return result

        return None
