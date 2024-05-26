"""
Providers register themselves and handle any setup that matches.

For… complexity's sake, this is done as a JSON dict.
Current known providers generally have two things to look for: Type, and ID.

1. type: ollama / id: http://localhost:11434
2. type: llamafile / id: ~/Downloads/llava-v1.5-7b-q4.llamafile
"""
from typing import TypeAlias, Callable, Awaitable

from pydantic import BaseModel

ProviderType: TypeAlias = str
ProviderID: TypeAlias = str


class ProviderConfig(BaseModel):
    type: ProviderType
    id: ProviderID


class BaseProvider:
    pass


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
    registered_funcs: list[ProviderFactory]

    def __init__(self):
        _Borg.__init__(self)

        if not hasattr(self, 'registered_funcs'):
            self.registered_funcs = []

    def register_factory(
            self,
            try_make_fn: ProviderFactory,
    ) -> None:
        self.registered_funcs.append(try_make_fn)

    async def make(self, config: ProviderConfig) -> BaseProvider | None:
        for try_make_fn in self.registered_funcs:
            result = await try_make_fn(config)
            if result is not None:
                print(f"ProviderRegistry.make: {config}")
                return result

        return None
