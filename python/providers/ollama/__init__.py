import asyncio
import logging
from datetime import datetime, timezone

import httpx
import orjson
from sqlalchemy import select

from providers._util import local_provider_identifiers, local_fetch_machine_info
from providers.inference_models.database import HistoryDB, get_db
from providers.orm import ProviderRecordOrm, ProviderLabel, ProviderRecord
from providers.registry import ProviderRegistry, BaseProvider

logger = logging.getLogger(__name__)

_real_ollama_client = httpx.AsyncClient(
    base_url="http://localhost:11434",
    http2=True,
    proxy=None,
    cert=None,
    timeout=httpx.Timeout(2.0, read=None),
    max_redirects=0,
    follow_redirects=False,
)


class OllamaProvider(BaseProvider):
    base_url: str
    client: httpx.AsyncClient

    def __init__(self, base_url: str):
        self.base_url = base_url
        self.client = httpx.AsyncClient(
            base_url=self.base_url,
            http2=True,
            proxy=None,
            cert=None,
            timeout=httpx.Timeout(2.0, read=None),
            max_redirects=0,
            follow_redirects=False,
        )

    async def available(self) -> bool:
        ping1 = self.client.build_request(
            method='HEAD',
            url='/',
        )
        response1 = await self.client.send(ping1)
        if response1.status_code != 200:
            logger.debug(f"Ping {self.base_url}: {response1.status_code=}")
            return False

        return True

    async def make_record(self) -> ProviderRecord:
        history_db: HistoryDB = next(get_db())

        provider_identifiers_dict = {
            "name": "ollama",
            "endpoint": self.base_url,
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


async def discover_servers():
    async def factory(label: ProviderLabel) -> OllamaProvider | None:
        if label.type != 'ollama':
            return None

        maybe_provider = OllamaProvider(base_url=label.id)
        if not await maybe_provider.available():
            logger.info(f"OllamaProvider endpoint offline, skipping: {label.id}")
            return None

        return maybe_provider

    registry = ProviderRegistry()
    registry.register_factory(factory)

    await registry.make(ProviderLabel(type="ollama", id="http://localhost:11434"))


async def build_executor_record(
        endpoint: str,
        do_commit: bool = True,
        history_db: HistoryDB | None = None,
) -> ProviderRecord:
    executor_singleton = OllamaProvider("http://localhost:11434")
    if endpoint != executor_singleton.base_url:
        logger.warning(f"Found `build_executor_record()` call with weird endpoint: {endpoint}")

    if not do_commit:
        logger.warning(f"Found a caller that wants {do_commit=}, ignoring")

    return executor_singleton.make_record()
