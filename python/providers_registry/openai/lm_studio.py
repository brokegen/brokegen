import logging
import os.path
from datetime import datetime, timezone
from typing import AsyncGenerator, AsyncIterator, Awaitable, TypeVar

import fastapi
import httpx
import orjson
import sqlalchemy
from _util.json import JSONDict, safe_get, safe_get_arrayed
from _util.status import ServerStatusHolder
from _util.typing import ChatSequenceID, PromptText
from audit.http import AuditDB
from audit.http import get_db as get_audit_db
from audit.http_raw import HttpxLogger
from client.database import HistoryDB, get_db as get_history_db
from client.message import ChatMessage, ChatMessageOrm
from client.sequence import ChatSequenceOrm
from client.sequence_get import fetch_messages_for_sequence
from inference.iterators import stream_str_to_json, consolidate_and_yield, tee_to_console_output
from inference.logging import construct_assistant_message
from providers.foundation_models.orm import FoundationModelRecord, InferenceEventOrm
from providers.foundation_models.orm import lookup_foundation_model_detailed, \
    FoundationModelAddRequest, FoundationModelRecordOrm
from providers.orm import ProviderRecordOrm, ProviderLabel, ProviderRecord, ProviderType
from providers.registry import ProviderRegistry, BaseProvider, ProviderFactory, InferenceOptions
from providers_registry._util import local_provider_identifiers, local_fetch_machine_info
from sqlalchemy import select

logger = logging.getLogger(__name__)

T = TypeVar('T')
U = TypeVar('U')


def chat_completion_choice0_extractor(chunk: JSONDict) -> str:
    response_choices = safe_get(chunk, "choices") or []
    if len(response_choices) > 1:
        logger.warning(f"Received {len(response_choices)=}, ignoring all but the first")

    return safe_get_arrayed(response_choices, 0, 'delta', 'content') or ""


def openai_response_consolidator(
        chunk: JSONDict,
        consolidated_response: JSONDict,
) -> JSONDict:
    """
    https://platform.openai.com/docs/api-reference/chat/streaming
    """
    if not consolidated_response:
        return chunk

    for k, v in chunk.items():
        if k not in consolidated_response:
            consolidated_response[k] = v
            continue

        elif k == 'choices':
            if len(v) > 1:
                logger.warning(f"Received {len(v)} completion choices, ignoring all but the first")

            if not safe_get_arrayed(consolidated_response, k, 0, 'delta', 'content'):
                consolidated_response[k][0]['delta']['content'] = safe_get_arrayed(v, 0, 'delta', 'content') or ""
            else:
                consolidated_response[k][0]['delta']['content'] += safe_get_arrayed(v, 0, 'delta', 'content') or ""

    return consolidated_response


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
        async def jsonner(
                primordial0: AsyncIterator[bytes],
        ) -> AsyncIterator[JSONDict]:
            async for chunk in primordial0:
                # The first few bytes of the lm_studio response always start with b'data: '
                if chunk[0:6] == b'data: ':
                    chunk = chunk[6:]

                # TODO: What the _hell_ is this chunk? Continuing.
                if chunk[0:6] == b'[DONE]':
                    continue

                try:
                    yield orjson.loads(chunk)
                except orjson.JSONDecodeError:
                    print(f"[ERROR] Failed to decode chunk, continuing: {chunk}")
                    continue

        async def update_status(
                primordial: AsyncIterator[JSONDict],
        ) -> AsyncIterator[JSONDict]:
            chunk_number: int = 0

            async for chunk in primordial:
                chunk_number += 1
                status_holder.set(f"[lm_studio] {inference_model.human_id}: received response chunk #{chunk_number}")

                if "status" not in chunk:
                    chunk["status"] = status_holder.get()

                yield chunk

            status_holder.set(f"[lm_studio] {inference_model.human_id}: done with inference")

        async def reformat_openai(
                primordial: AsyncIterator[JSONDict],
        ) -> AsyncIterator[JSONDict]:
            async for chunk in primordial:
                current_time = datetime.now(tz=timezone.utc)
                if chat_completion_choice0_extractor(chunk):
                    yield {
                        "model": inference_model.human_id,
                        "created_at": current_time.isoformat() + "Z",
                        "done": False,
                        "message": {
                            "role": "assistant",
                            "content": chat_completion_choice0_extractor(chunk),
                        }
                    }
                else:
                    # This is really important for the output from `append_response_chunk`
                    yield chunk

        async def append_response_chunk(
                consolidated_response: JSONDict,
        ) -> AsyncIterator[JSONDict]:
            # And now, construct the ChatSequence (which references the InferenceEvent, actually)
            try:
                inference_event = InferenceEventOrm(
                    model_record_id=inference_model.id,
                    prompt_with_templating=None,
                    response_created_at=datetime.now(tz=timezone.utc),
                    response_info=consolidated_response,
                    reason="LMStudioProvider.do_chat_logged",
                )

                if safe_get(consolidated_response, 'error'):
                    inference_event.response_error = safe_get(consolidated_response, 'error', 'message')
                else:
                    inference_event.response_error = None

                history_db.add(inference_event)
                history_db.commit()

                response_message: ChatMessageOrm | None = construct_assistant_message(
                    maybe_response_seed=inference_options.seed_assistant_response or "",
                    assistant_response=chat_completion_choice0_extractor(consolidated_response),
                    created_at=inference_event.response_created_at,
                    history_db=history_db,
                )
                if not response_message:
                    print(f"[ERROR] Failed to construct_assistant_message() from \"{chat_completion_choice0_extractor(consolidated_response)}\"")
                    return

                original_sequence: ChatSequenceOrm = history_db.execute(
                    select(ChatSequenceOrm)
                    .where(ChatSequenceOrm.id == sequence_id)
                ).scalar_one()

                # TODO: Replace with `construct_new_sequence_from`
                response_sequence = ChatSequenceOrm(
                    human_desc=original_sequence.human_desc,
                    user_pinned=False,
                    current_message=response_message.id,
                    parent_sequence=original_sequence.id,
                )

                history_db.add(response_sequence)

                response_sequence.generated_at = inference_event.response_created_at
                response_sequence.generation_complete = True
                response_sequence.inference_job_id = inference_event.id
                if inference_event.response_error:
                    response_sequence.inference_error = inference_event.response_error

                history_db.commit()

                # And complete the circular reference that really should be handled in the SQLAlchemy ORM
                inference_job = history_db.merge(inference_event)
                inference_job.parent_sequence = response_sequence.id

                history_db.add(inference_job)
                history_db.commit()

                # Return fields that the client probably cares about
                yield {
                    "new_message_id": response_sequence.current_message,
                    "new_sequence_id": response_sequence.id,
                    "done": True,
                }

            except sqlalchemy.exc.SQLAlchemyError:
                logger.exception(f"Failed to create add-on ChatSequence from {consolidated_response}")
                history_db.rollback()
                status_holder.set(f"Failed to create add-on ChatSequence from {consolidated_response}")
                yield {
                    "error": "Failed to create add-on ChatSequence",
                    "done": True,
                }

            except Exception:
                logger.exception(f"Failed to create add-on ChatSequence from {consolidated_response}")
                status_holder.set(f"Failed to create add-on ChatSequence from {consolidated_response}")
                yield {
                    "error": "Failed to create add-on ChatSequence",
                    "done": True,
                }

        # TODO: make system messages/overrides available here
        messages_list: list[ChatMessage] = fetch_messages_for_sequence(sequence_id, history_db)

        request_content = {
            'stream': True,
        }
        request_content.update(orjson.loads(inference_options.inference_options or "{}"))
        request_content['messages'] = [
            message.model_dump() for message in messages_list
        ]
        request_content['model'] = inference_model.human_id

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

            iter0: AsyncIterator[bytes] = upstream_response.aiter_bytes()
            iter1: AsyncIterator[JSONDict] = jsonner(iter0)
            iter2: AsyncIterator[JSONDict] = tee_to_console_output(iter1, chat_completion_choice0_extractor)
            iter3: AsyncIterator[JSONDict] = consolidate_and_yield(
                iter2, openai_response_consolidator, {},
                append_response_chunk,
            )
            iter4: AsyncIterator[JSONDict] = reformat_openai(iter3)
            iter5: AsyncIterator[JSONDict] = update_status(iter4)

            return iter5


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
