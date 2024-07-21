import logging
from abc import abstractmethod
from typing import AsyncGenerator, Self, AsyncIterator, Awaitable, Optional

from pydantic import BaseModel

from _util.json import JSONDict
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, PromptText, TemplatedPromptText
from audit.http import AuditDB
from client.database import HistoryDB
from client.message import ChatMessage
from client.sequence_get import fetch_messages_for_sequence
from .foundation_models.orm import FoundationModelRecord, FoundationModelResponse, FoundationModelRecordOrm
from .orm import ProviderLabel, ProviderRecord, ProviderType

logger = logging.getLogger(__name__)


class InferenceOptions(BaseModel):
    inference_options: Optional[str] = None
    override_model_template: Optional[str] = None
    override_system_prompt: Optional[PromptText] = None
    seed_assistant_response: Optional[PromptText] = None


class BaseProvider:
    cached_model_infos: list[FoundationModelRecord] = []

    @abstractmethod
    async def available(self) -> bool:
        raise NotImplementedError()

    @abstractmethod
    async def make_record(self) -> ProviderRecord:
        raise NotImplementedError()

    @abstractmethod
    async def list_models_nocache(
            self,
    ) -> AsyncGenerator[FoundationModelRecord, None]:
        raise NotImplementedError()

    async def list_models(
            self,
    ) -> AsyncGenerator[FoundationModelRecord, None]:
        """Caching version."""
        if self.cached_model_infos:
            for model_info in self.cached_model_infos:
                yield model_info

        else:
            async for model_info in self.list_models_nocache():
                yield model_info
                self.cached_model_infos.append(model_info)

    @abstractmethod
    async def do_chat_nolog(
            self,
            messages_list: list[ChatMessage],
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        """
        Dump a sequence of JSON blobs, roughly equivalent to the Ollama output format.
        Note that the concrete Providers are expected to record an InferenceEvent, and by extension the ChatMessage/ChatSequence.

        Key differences:

        - a `status` field is supported, to surface what the server is doing
        - an `autoname`/`human_desc` field may also be included, when we have auto-named the ChatSequence
        - the final packet can include a `new_sequence_id`, so the client doesn't have to auto-fetch new info

        Any InferenceEvent logging will be done per-provider, since only the provider knows what was generated.
        However, autonaming and context retrieval can happen separately.
        """
        raise NotImplementedError()

    @abstractmethod
    async def do_chat_logged(
            self,
            sequence_id: ChatSequenceID,
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        raise NotImplementedError()

    async def chat(
            self,
            sequence_id: ChatSequenceID,
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            retrieval_context: Awaitable[PromptText | None],
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        # NB This isn't used anywhere, yet, so we don't care
        await retrieval_context

        try:
            return await self.do_chat_logged(
                sequence_id,
                inference_model,
                inference_options,
                status_holder,
                history_db,
                audit_db,
            )

        except NotImplementedError:
            messages_list: list[ChatMessage] = fetch_messages_for_sequence(sequence_id, history_db)

            return await self.do_chat_nolog(
                messages_list,
                inference_model,
                inference_options,
                status_holder,
                history_db,
                audit_db,
            )

    @abstractmethod
    def generate(
            self,
            prompt: TemplatedPromptText,
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncGenerator[JSONDict, None]:
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

            except Exception:
                logger.info(f"{factory.__class__} could not load {label}")

        return None

    def provider_from(
            self,
            inference_model: FoundationModelRecord | FoundationModelResponse,
    ) -> ProviderLabel | None:
        matching_provider: BaseProvider | None = None
        for provider_record, provider in self.by_record.items():
            if inference_model.provider_identifiers == provider_record.identifiers:
                matching_provider = provider

        return matching_provider

    def provider_label_from(
            self,
            inference_model: FoundationModelRecord | FoundationModelResponse,
    ) -> ProviderLabel | None:
        matching_provider: BaseProvider | None = self.provider_from(inference_model)
        if matching_provider is None:
            return None

        for label, provider in self.by_label.items():
            if matching_provider == provider:
                return label

        return None
