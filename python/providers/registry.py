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

import orjson
from pydantic import BaseModel, ConfigDict

ProviderType: TypeAlias = str
ProviderID: TypeAlias = str

logger = logging.getLogger(__name__)


class ProviderConfig(BaseModel):
    type: ProviderType
    id: ProviderID

    model_config = ConfigDict(
        extra='forbid',
        frozen=True,
    )


class ProviderRecord(BaseModel):
    identifiers: str
    created_at: datetime

    machine_info: Optional[dict] = None
    human_info: Optional[str] = None

    model_config = ConfigDict(
        extra='forbid',
        from_attributes=True,
        frozen=True,
    )

    def __hash__(self) -> int:
        return hash((
            self.identifiers,
            self.created_at,
            # NB This is odd, and requires the class to be immutable
            orjson.dumps(self.machine_info),
            self.human_info,
        ))


class BaseProvider:
    @abstractmethod
    async def available(self) -> bool:
        raise NotImplementedError()

    @abstractmethod
    async def make_record(self) -> ProviderRecord:
        raise NotImplementedError()


ProviderFactory: TypeAlias = Callable[[ProviderConfig], Awaitable[BaseProvider | None]]
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
    by_config: dict[ProviderConfig, BaseProvider]
    by_record: dict[ProviderRecord, BaseProvider]

    def __init__(self):
        _Borg.__init__(self)

        if not hasattr(self, '_factories'):
            self._factories = []
        if not hasattr(self, 'by_config'):
            self.by_config = {}
        if not hasattr(self, 'by_record'):
            self.by_record = {}

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
