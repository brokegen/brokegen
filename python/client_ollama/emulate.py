import hashlib
import json
import logging
from datetime import datetime, timezone
from typing import AsyncIterable, Awaitable, AsyncIterator, AsyncGenerator

import orjson
import starlette.requests
import starlette.responses
from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy import select
from starlette.requests import Request

from _util.json import JSONDict, safe_get, JSONArray
from _util.json_streaming import JSONStreamingResponse, emit_keepalive_chunks
from _util.status import ServerStatusHolder
from _util.typing import FoundationModelHumanID, FoundationModelRecordID, PromptText
from audit.http import AuditDB, get_db as get_audit_db
from client.database import HistoryDB, get_db as get_history_db
from client.sequence import ChatSequenceOrm
from inference.iterators import dump_to_bytes
from providers.foundation_models.orm import FoundationModelRecord, FoundationModelRecordOrm
from providers.orm import ProviderID, ProviderType, ProviderLabel
from providers.registry import ProviderRegistry, BaseProvider, InferenceOptions
from providers_registry.ollama.api_chat.logging import OllamaRequestContentJSON, OllamaResponseContentJSON, \
    OllamaGenerateResponse
from .emulate_api_chat import do_capture_chat_messages
from .forward import forward_request

logger = logging.getLogger(__name__)


def pack_name(label: ProviderLabel, model_id: FoundationModelRecordID, human_id: FoundationModelHumanID) -> str:
    return f"{model_id}::{human_id}"


def unpack_name(name: str) -> tuple[FoundationModelRecordID, FoundationModelHumanID]:
    components = name.split("::")
    return components[0], components[1]


async def emulate_api_tags(
        label: ProviderLabel,
        provider: BaseProvider,
) -> AsyncIterable[JSONDict]:
    model: FoundationModelRecord
    async for model in provider.list_models_nocache():
        def compute_hash() -> str:
            sha256_hasher = hashlib.sha256()
            sha256_hasher.update(model.provider_identifiers.encode())
            sha256_hasher.update(orjson.dumps(model.model_identifiers, option=orjson.OPT_SORT_KEYS))

            return sha256_hasher.hexdigest()

        model_out = {
            "name": pack_name(label, model.id, model.human_id),
            "model": model.human_id,
            "digest": compute_hash(),
            "size": 0,
            # TODO: Figure out when to append "Z", and why it isn't appended sometimes.
            "modified_at": model.first_seen_at.isoformat() + "Z",
            "details": {
                "parent_model": "",
                "format": "gguf",
            },
            "model_identifiers": model.model_identifiers,
            "provider_identifiers": model.provider_identifiers,
        }

        yield model_out


async def emulate_api_show(
        packed_model_name: str,
        history_db: HistoryDB,
) -> JSONDict:
    _, _ = unpack_name(packed_model_name)
    return {}


async def _do_keepalive(
        primordial: AsyncIterator[OllamaGenerateResponse],
        request_content: OllamaResponseContentJSON,
) -> AsyncGenerator[JSONDict, None]:
    async for chunk in emit_keepalive_chunks(primordial, 3.0, None):
        if chunk is None:
            current_time = datetime.now(tz=timezone.utc)
            yield {
                "model": safe_get(request_content, "model"),
                "created_at": current_time.isoformat() + "Z",
                "done": False,
                "response": "",
            }

        else:
            yield chunk


async def emulate_api_generate(
        request_content: OllamaRequestContentJSON,
        status_holder: ServerStatusHolder,
        history_db: HistoryDB,
        audit_db: AuditDB,
        registry: ProviderRegistry,
) -> AsyncIterator[OllamaGenerateResponse]:
    model_id, human_id = unpack_name(request_content['model'])

    inference_model: FoundationModelRecordOrm = history_db.execute(
        select(FoundationModelRecordOrm)
        .where(FoundationModelRecordOrm.id == model_id)
        .order_by(FoundationModelRecordOrm.last_seen.desc())
        .limit(1)
    ).scalar_one_or_none()
    if inference_model is None:
        raise RuntimeError(f"Couldn't find foundation model with {model_id=}")

    provider: BaseProvider | None = registry.provider_from(inference_model)

    async def real_response_maker() -> AsyncIterator[JSONDict]:
        if safe_get(request_content, "raw"):
            logger.warning("Ollama client provided \"raw\" flag, ignoring")

        enumerator: AsyncGenerator[JSONDict, None]
        enumerator = provider.generate(
            prompt=safe_get(request_content, "prompt"),
            inference_model=inference_model,
            inference_options=safe_get(request_content, "options"),
            status_holder=status_holder,
            history_db=history_db,
            audit_db=audit_db,
        )

        return enumerator

    async def nonblocking_response_maker(
            real_response_maker: Awaitable[AsyncIterator[JSONDict]],
    ) -> AsyncIterator[OllamaGenerateResponse]:
        async for item in (await real_response_maker):
            yield item

    awaitable: Awaitable[AsyncIterator[JSONDict]] = real_response_maker()
    iter0: AsyncIterator[JSONDict] = nonblocking_response_maker(awaitable)
    return iter0


async def emulate_api_chat(
        original_request: starlette.requests.Request,
        status_holder: ServerStatusHolder,
        history_db: HistoryDB,
        audit_db: AuditDB,
        registry: ProviderRegistry,
) -> AsyncIterator[OllamaGenerateResponse]:
    request_content: dict = orjson.loads(await original_request.body())
    model_id, human_id = unpack_name(request_content['model'])

    inference_model: FoundationModelRecordOrm = history_db.execute(
        select(FoundationModelRecordOrm)
        .where(FoundationModelRecordOrm.id == model_id)
        .order_by(FoundationModelRecordOrm.last_seen.desc())
        .limit(1)
    ).scalar_one_or_none()
    if inference_model is None:
        raise RuntimeError(f"Couldn't find foundation model with {model_id=}")

    provider: BaseProvider | None = registry.provider_from(inference_model)

    async def real_response_maker(request_content: JSONDict) -> AsyncIterator[JSONDict]:
        # Assume that these are messages from a third-party client, and try to feed them into the history database.
        chat_messages: JSONArray | None = safe_get(request_content, 'messages')
        if not chat_messages:
            raise RuntimeError("No 'messages' provided in call to /api/chat")

        captured_sequence: ChatSequenceOrm | None
        requested_system_message: PromptText | None
        captured_sequence, requested_system_message = do_capture_chat_messages(chat_messages, history_db)

        async def no_retrieval_context() -> PromptText | None:
            return None

        return await provider.chat(
            sequence_id=captured_sequence.id,
            inference_model=inference_model,
            inference_options=InferenceOptions(
                inference_options=json.dumps(safe_get(request_content, "options")),
            ),
            retrieval_context=no_retrieval_context(),
            status_holder=status_holder,
            history_db=history_db,
            audit_db=audit_db,
        )

    async def nonblocking_response_maker(
            real_response_maker: Awaitable[AsyncIterator[JSONDict]],
    ) -> AsyncIterator[OllamaGenerateResponse]:
        async for item in (await real_response_maker):
            yield item

    awaitable: Awaitable[AsyncIterator[JSONDict]] = real_response_maker(request_content)
    iter0: AsyncIterator[JSONDict] = nonblocking_response_maker(awaitable)
    return iter0


def install_forwards(router_ish: FastAPI):
    @router_ish.get("/providers/any/any/ollama-emulate/{ollama_get_path:path}")
    @router_ish.get("/ollama-emulate/{ollama_get_path:path}")
    @router_ish.post("/ollama-emulate/{ollama_post_path:path}")
    async def ollama_get(
            original_request: starlette.requests.Request,
            ollama_get_path: str | None = None,
            ollama_post_path: str | None = None,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        if ollama_get_path == "api/tags":
            collected_model_info = []
            for label, provider in ProviderRegistry().by_label.items():
                collected_model_info.extend(
                    [m async for m in emulate_api_tags(label, provider)]
                )

            return {"models": collected_model_info}

        if ollama_post_path == "api/show":
            request_content: dict = orjson.loads(await original_request.body())
            return await emulate_api_show(request_content['name'], history_db)

        if ollama_post_path == "api/generate":
            async def add_newlines(primordial: AsyncIterator[bytes]) -> AsyncIterator[bytes]:
                async for chunk in primordial:
                    yield chunk + b'\n'

            status_holder = ServerStatusHolder("Processing /api/generate")
            request_content: dict = orjson.loads(await original_request.body())

            iter0: AsyncIterator[OllamaResponseContentJSON] = await emulate_api_generate(
                request_content, status_holder, history_db, audit_db, registry)
            iter1: AsyncIterator[OllamaGenerateResponse] = _do_keepalive(iter0, request_content)
            iter2: AsyncIterator[bytes] = dump_to_bytes(iter1)
            iter3: AsyncIterator[bytes] = add_newlines(iter2)

            return JSONStreamingResponse(
                content=iter3,
                status_code=218,
            )

        if ollama_post_path == "api/chat":
            status_holder = ServerStatusHolder("Processing /api/chat")
            return await emulate_api_chat(
                original_request, status_holder, history_db, audit_db, registry)

        raise HTTPException(501, "endpoint not implemented")

    @router_ish.get("/providers/{provider_type:str}/{provider_id:path}/ollama-emulate/{ollama_get_path:path}")
    @router_ish.post("/providers/{provider_type:str}/{provider_id:path}/ollama-emulate/{ollama_post_path:path}")
    async def ollama_get_or_post(
            original_request: Request,
            provider_type: ProviderType,
            provider_id: ProviderID,
            ollama_get_path: str | None = None,
            ollama_post_path: str | None = None,
            history_db: HistoryDB = Depends(get_history_db),
            audit_db: AuditDB = Depends(get_audit_db),
            registry: ProviderRegistry = Depends(ProviderRegistry),
    ):
        label = ProviderLabel(type=provider_type, id=provider_id)
        provider = registry.by_label[label]

        if ollama_get_path == "api/tags":
            return {"models": [m async for m in emulate_api_tags(label, provider)]}

        if ollama_post_path == "api/show":
            request_content_json: dict = orjson.loads(await original_request.body())

            from providers_registry.ollama.models.list import do_api_show
            return await do_api_show(request_content_json['name'], history_db, audit_db)

        return await forward_request(original_request, audit_db)

    # TODO: Using a router prefix breaks this, somehow
    @router_ish.head("/ollama-emulate/")
    async def proxy_head(
            request: starlette.requests.Request,
    ):
        return starlette.responses.Response()

    @router_ish.head("/providers/{provider_type:str}/{provider_id:path}/ollama/")
    async def ollama_head(
            original_request: Request,
            provider_type: ProviderType,
            provider_id: ProviderID,
    ):
        """
        This implementation isn't correct, but clients only check "HEAD /", anyway.
        """
        pass
