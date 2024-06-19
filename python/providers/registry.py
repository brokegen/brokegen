"""
Providers register themselves and handle any setup that matches.

For… complexity's sake, this is done as a JSON dict.
Current known providers generally have two things to look for: Type, and ID.

1. type: ollama / id: http://localhost:11434
2. type: llamafile / id: ~/Downloads/llava-v1.5-7b-q4.llamafile
"""
import logging
from abc import abstractmethod
from typing import AsyncGenerator, AsyncIterable, Self, AsyncIterator, Awaitable

from _util.json import JSONDict
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, PromptText
from audit.http import AuditDB
from inference.continuation import InferenceOptions
from providers.inference_models.database import HistoryDB
from providers.inference_models.orm import InferenceModelRecord, InferenceModelResponse, InferenceModelRecordOrm
from providers.orm import ProviderLabel, ProviderRecord, ProviderType

logger = logging.getLogger(__name__)


class BaseProvider:
    @abstractmethod
    async def available(self) -> bool:
        raise NotImplementedError()

    @abstractmethod
    async def make_record(self) -> ProviderRecord:
        raise NotImplementedError()

    @abstractmethod
    def list_models(self) -> (
            AsyncGenerator[InferenceModelRecord | InferenceModelResponse, None]
            | AsyncIterable[InferenceModelRecord | InferenceModelResponse]):
        """
        Method not marked async because it returns AsyncGenerator
        """
        raise NotImplementedError()

    @abstractmethod
    async def chat(
            self,
            sequence_id: ChatSequenceID,
            inference_model: InferenceModelRecordOrm,
            inference_options: InferenceOptions,
            retrieval_context: Awaitable[PromptText | None],
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        """
        Dump a sequence of JSON blobs, roughly equivalent to the Ollama output format.

        Key differences:

        - a `status` field is supported, to surface what the server is doing
        - an `autoname`/`human_desc` field may also be included, when we have auto-named the ChatSequence
        - the final packet can include a `new_sequence_id`, so the client doesn't have to auto-fetch new info

        Any InferenceEvent logging will be done per-provider, since only the provider knows what was generated.
        However, autonaming and context retrieval can happen separately.
        """
        raise NotImplementedError()


class ProviderFactory:
    @abstractmethod
    async def try_make(self, label: ProviderLabel) -> BaseProvider | None:
        """
        Try start + start is a single combined function because Providers are expected to be low overhead.
        In cases where we manage our own servers (llamafile, llama.cpp), we expect those Providers to quietly manage resources.
        """
        raise NotImplementedError()

    @abstractmethod
    async def discover(
            self,
            provider_type: ProviderType | None,
            registry: "ProviderRegistry",
    ) -> None:
        raise NotImplementedError()


class _Borg:
    _shared_state = {}

    def __init__(self):
        self.__dict__ = self._shared_state


class ProviderRegistry(_Borg):
    factories: list[ProviderFactory]
    by_label: dict[ProviderLabel, BaseProvider]
    by_record: dict[ProviderRecord, BaseProvider]

    def __init__(self):
        _Borg.__init__(self)

        if not hasattr(self, 'factories'):
            self.factories = []
        if not hasattr(self, 'by_label'):
            self.by_label = {}
        if not hasattr(self, 'by_record'):
            self.by_record = {}

    def register_factory(self, factory: ProviderFactory) -> Self:
        self.factories.append(factory)
        return self

    async def try_make(self, label: ProviderLabel) -> BaseProvider | None:
        if label in self.by_label:
            return self.by_label[label]

        for factory in self.factories:
            try:
                result = await factory.try_make(label)
                if result is not None:
                    logger.debug(f"ProviderRegistry.make succeeded: {label}")

                    self.by_label[label] = result
                    self.by_record[await result.make_record()] = result
                    return result

            except Exception as e:
                logger.error(f"Could not load {label}: {e}")

        return None

    def provider_from(
            self,
            inference_model: InferenceModelRecord | InferenceModelResponse,
    ) -> ProviderLabel | None:
        matching_provider: BaseProvider | None = None
        for provider_record, provider in self.by_record.items():
            if inference_model.provider_identifiers == provider_record.identifiers:
                matching_provider = provider

        return matching_provider

    def provider_label_from(
            self,
            inference_model: InferenceModelRecord | InferenceModelResponse,
    ) -> ProviderLabel | None:
        matching_provider: BaseProvider | None = self.provider_from(inference_model)
        if matching_provider is None:
            return None

        for label, provider in self.by_label.items():
            if matching_provider == provider:
                return label

        return None
