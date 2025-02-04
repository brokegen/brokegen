import logging
import os.path
from datetime import datetime, timezone
from typing import AsyncGenerator, AsyncIterator, Awaitable, TypeVar, Callable

import fastapi
import httpx
import orjson
from _util.json import JSONDict, safe_get
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, PromptText
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from audit.http_raw import HttpxLogger
from client.database import HistoryDB, get_db as get_history_db
from client.message import ChatMessage
from client.sequence_get import fetch_messages_for_sequence
from inference.iterators import stream_str_to_json, consolidate_and_call, consolidate_and_yield
from providers.foundation_models.orm import FoundationModelRecord, InferenceEventOrm
from providers.foundation_models.orm import lookup_foundation_model_detailed, \
    FoundationModelAddRequest, FoundationModelRecordOrm
from providers.orm import ProviderRecordOrm, ProviderLabel, ProviderRecord, ProviderType
from providers.registry import ProviderRegistry, BaseProvider, ProviderFactory, InferenceOptions
from providers_registry._util import local_provider_identifiers, local_fetch_machine_info
from providers_registry.ollama.api_chat.logging import ollama_response_consolidator
from sqlalchemy import select

logger = logging.getLogger(__name__)

T = TypeVar('T')
U = TypeVar('U')


class LMStudioProvider(BaseProvider):
    """
    LM Studio requires the user to pick a specific model to load for the server,
    so this is less useful than something like Ollama that provides an API for model-loading.
    """

    server_comms: httpx.AsyncClient
    apply_our_own_templating: bool

    def __init__(
            self,
            base_url: str,
            apply_our_own_templating: bool = False,
    ):
        super().__init__()
        self.server_comms = httpx.AsyncClient(
            base_url=base_url,
            http2=True,
            proxy=None,
            cert=None,
            timeout=httpx.Timeout(2.0, read=None),
            max_redirects=0,
            follow_redirects=False,
        )

        self.apply_our_own_templating = apply_our_own_templating

    async def available(self) -> bool:
        ping1 = self.server_comms.build_request(
            method='GET',
            url='/v1/models',
            # https://github.com/encode/httpx/discussions/2959
            # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
            headers=[('Connection', 'close')],
        )
        response = await self.server_comms.send(ping1)
        await response.aclose()

        if response.status_code != 200:
            logger.error(f"{self.server_comms.base_url} not available, response returned: {response}")
            return False

        return True

    async def make_record(self) -> ProviderRecord:
        history_db: HistoryDB = next(get_history_db())

        # NB We are skipping most things, like `apply_our_own_templating`, because
        # we don't get enough identifiers from upstream anyway.
        provider_identifiers_dict = {
            "name": "lm_studio",
            "endpoint": str(self.server_comms.base_url),
        }
        provider_identifiers_dict.update(await local_provider_identifiers())

        provider_identifiers = orjson.dumps(provider_identifiers_dict, option=orjson.OPT_SORT_KEYS)

        # Check for existing matches
        maybe_provider = history_db.execute(
            select(ProviderRecordOrm)
            .where(ProviderRecordOrm.identifiers == provider_identifiers)
        ).scalar_one_or_none()
        if maybe_provider is not None:
            return ProviderRecord.model_validate(maybe_provider)

        new_provider = ProviderRecordOrm(
            identifiers=provider_identifiers,
            created_at=datetime.now(tz=timezone.utc),
            machine_info=await local_fetch_machine_info(),
        )
        history_db.add(new_provider)
        history_db.commit()

        return ProviderRecord.model_validate(new_provider)

    async def list_models_nocache(
            self,
    ) -> AsyncGenerator[FoundationModelRecord, None]:
        request = self.server_comms.build_request(
            method='GET',
            url='/v1/models',
            # https://github.com/encode/httpx/discussions/2959
            # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
            headers=[('Connection', 'close')],
        )
        response = await self.server_comms.send(request)
        if response.status_code != 200:
            raise fastapi.HTTPException(
                response.status_code,
                detail=response.content,
                headers=response.headers,
            )
        await response.aclose()

        response_content: JSONDict = response.json()
        if safe_get(response_content, "object") != "list":
            logger.error(f"Unrecognized response format: {response_content.keys()}")

        access_time = datetime.now(tz=timezone.utc)
        for model_identifiers in response_content["data"]:
            model_in = FoundationModelAddRequest(
                human_id=os.path.basename(safe_get(model_identifiers, 'id')),
                first_seen_at=access_time,
                last_seen=access_time,
                provider_identifiers=(await self.make_record()).identifiers,
                model_identifiers=model_identifiers,
                combined_inference_parameters=None,
            )

            history_db: HistoryDB = next(get_history_db())

            maybe_model = lookup_foundation_model_detailed(model_in, history_db)
            if maybe_model is not None:
                maybe_model.merge_in_updates(model_in)
                history_db.add(maybe_model)
                history_db.commit()

                yield FoundationModelRecord.model_validate(maybe_model)
                continue

            else:
                logger.info(f"GET /v1/models returned a new FoundationModelRecord: {safe_get(model_identifiers, 'id')}")
                new_model = FoundationModelRecordOrm(**model_in.model_dump())
                history_db.add(new_model)
                history_db.commit()

                yield FoundationModelRecord.model_validate(new_model)
                continue

    async def do_chat_nolog(
            self,
            messages_list: list[ChatMessage],
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        request_content = dict(
            orjson.loads(inference_options.inference_options or "{}")
        )
        request_content['model'] = inference_model.human_id
        request_content['messages'] = [
            message.model_dump() for message in messages_list
        ]

        request = self.server_comms.build_request(
            method='POST',
            url='/v1/chat/completions',
            content=orjson.dumps(request_content),
            # https://github.com/encode/httpx/discussions/2959
            # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
            headers=[('Connection', 'close')],
        )

        upstream_response = await self.server_comms.send(request, stream=True)

        iter0: AsyncIterator[str] = upstream_response.aiter_text()
        iter1: AsyncIterator[JSONDict] = stream_str_to_json(iter0)

        return iter1

    async def do_chat(
            self,
            sequence_id: ChatSequenceID,
            inference_model: FoundationModelRecordOrm,
            inference_options: InferenceOptions,
            retrieval_context: Awaitable[PromptText | None],
            status_holder: ServerStatusHolder,
            history_db: HistoryDB,
            audit_db: AuditDB,
    ) -> AsyncIterator[JSONDict]:
        messages_list: list[ChatMessage] = fetch_messages_for_sequence(sequence_id, history_db)

        request_content = {
            'stream': True,
        }
        request_content.update(orjson.loads(inference_options.inference_options or "{}"))
        request_content['messages'] = [
            message.model_dump() for message in messages_list
        ]
        request_content['model'] = inference_model.human_id

        inference_event = InferenceEventOrm(
            model_record_id=inference_model.id,
            prompt_with_templating=None,
            response_created_at=datetime.now(tz=timezone.utc),
            response_error="[haven't received/finalized response info yet]",
            reason=None,
        )
        history_db.add(inference_event)
        history_db.commit()

        def do_finalize_inference_job(response_content):
            merged_inference_event = history_db.merge(inference_event)
            if safe_get(response_content, 'error'):
                inference_event.response_error = safe_get(response_content, 'error', 'message')
            else:
                inference_event.response_error = None

            history_db.add(merged_inference_event)
            history_db.commit()

        with HttpxLogger(self.server_comms, next(get_audit_db())):
            headers = httpx.Headers()
            headers['content-type'] = 'application/json'
            # https://github.com/encode/httpx/discussions/2959
            # httpx tries to reuse a connection later on, but asyncio can't, so "RuntimeError: Event loop is closed"
            headers['connection'] = 'close'

            request = self.server_comms.build_request(
                method='POST',
                url='/v1/chat/completions',
                content=orjson.dumps(request_content),
                headers=headers,
            )
            upstream_response: httpx.Response
            upstream_response = await self.server_comms.send(request, stream=True)

            iter0: AsyncIterator[str] = upstream_response.aiter_text()
            iter1: AsyncIterator[JSONDict] = stream_str_to_json(iter0)
            iter2: AsyncIterator[JSONDict] = consolidate_and_yield(
                iter1, ollama_response_consolidator, {},
                do_finalize_inference_job,
            )

            return iter2


class LMStudioFactory(ProviderFactory):
    async def try_make_nocache(self, label: ProviderLabel) -> LMStudioProvider | None:
        if label.type != 'lm_studio':
            return None

        maybe_provider = LMStudioProvider(base_url=label.id)
        if not await maybe_provider.available():
            logger.info(f"LMStudioProvider offline, skipping: {label.id}")
            return None

        return maybe_provider

    async def discover(self, provider_type: ProviderType | None, registry: ProviderRegistry) -> None:
        if provider_type is not None and provider_type != 'lm_studio':
            return

        label = ProviderLabel(type="lm_studio", id="http://localhost:1234")
        await registry.try_make(label)
