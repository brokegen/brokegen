import logging
from datetime import datetime, timezone
from typing import AsyncIterable

import fastapi
import httpx
import orjson
from sqlalchemy import select

from _util.json import JSONDict, safe_get
from providers._util import local_provider_identifiers, local_fetch_machine_info
from providers.inference_models.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceModelRecord
from providers.inference_models.orm import lookup_inference_model_detailed, \
    InferenceModelAddRequest, InferenceModelRecordOrm
from providers.orm import ProviderRecordOrm, ProviderLabel, ProviderRecord, ProviderType
from providers.registry import ProviderRegistry, BaseProvider, ProviderFactory

logger = logging.getLogger(__name__)


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
        provider_identifiers_dict.update(local_provider_identifiers())

        provider_identifiers = orjson.dumps(provider_identifiers_dict, option=orjson.OPT_SORT_KEYS)

        # Check for existing matches
        maybe_provider = history_db.execute(
            select(ProviderRecordOrm)
            .where(ProviderRecordOrm.identifiers == provider_identifiers)
        ).scalar_one_or_none()
        if maybe_provider is not None:
            return ProviderRecord.from_orm(maybe_provider)

        new_provider = ProviderRecordOrm(
            identifiers=provider_identifiers,
            created_at=datetime.now(tz=timezone.utc),
            machine_info=await local_fetch_machine_info(),
        )
        history_db.add(new_provider)
        history_db.commit()

        return ProviderRecord.from_orm(new_provider)

    async def list_models(self) -> AsyncIterable[InferenceModelRecord]:
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
            model_in = InferenceModelAddRequest(
                human_id=safe_get(model_identifiers, 'id'),
                first_seen_at=access_time,
                last_seen=access_time,
                provider_identifiers=(await self.make_record()).identifiers,
                model_identifiers=model_identifiers,
                combined_inference_parameters=None,
            )

            history_db: HistoryDB = next(get_history_db())

            maybe_model = lookup_inference_model_detailed(model_in, history_db)
            if maybe_model is not None:
                maybe_model.merge_in_updates(model_in)
                history_db.add(maybe_model)
                history_db.commit()

                yield InferenceModelRecord.from_orm(maybe_model)
                continue

            else:
                logger.info(f"GET /v1/models returned a new InferenceModelRecord: {safe_get(model_identifiers, 'id')}")
                new_model = InferenceModelRecordOrm(**model_in.model_dump())
                history_db.add(new_model)
                history_db.commit()

                yield InferenceModelRecord.from_orm(new_model)
                continue


class LMStudioFactory(ProviderFactory):
    async def try_make(self, label: ProviderLabel) -> LMStudioProvider | None:
        if label.type != 'lm_studio':
            return None

        maybe_provider = LMStudioProvider(base_url=label.id)
        if not await maybe_provider.available():
            logger.info(f"LMStudioProvider offline, skipping: {label.id}")
            return None

        return maybe_provider

    async def discover(self, provider_type: ProviderType | None, registry: ProviderRegistry) -> None:
        if provider_type != 'lm_studio':
            return

        await registry.make(ProviderLabel(type="lm_studio", id="http://localhost:1234"))
