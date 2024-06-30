import logging
from typing import Tuple

from fastapi import HTTPException
from sqlalchemy import select

from _util.json import safe_get
from _util.typing import FoundationModelHumanID
from audit.http import AuditDB
from client.database import HistoryDB
from providers.foundation_models.orm import FoundationModelRecordOrm, lookup_foundation_model
from providers.orm import ProviderLabel, ProviderRecord, ProviderRecordOrm
from providers.registry import ProviderRegistry
from .list import do_api_show, _real_ollama_client

logger = logging.getLogger(__name__)


async def lookup_model_offline(
        model_name: FoundationModelHumanID,
        history_db: HistoryDB,
) -> Tuple[FoundationModelRecordOrm, ProviderRecord]:
    provider = await ProviderRegistry().try_make(ProviderLabel(type="ollama", id="http://localhost:11434"))
    if provider is None:
        raise RuntimeError("No Provider loaded")

    provider_record = await provider.make_record()
    model = lookup_foundation_model(model_name, provider_record.identifiers, history_db)
    if not model:
        raise ValueError("Trying to look up model that doesn't exist, you should create it first")
    if not safe_get(model.combined_inference_parameters, 'template'):
        logger.error(f"No ollama template info for {model.human_id}, call /api/show to populate it")
        raise RuntimeError(
            f"No model template available for {model_name}, confirm that FoundationModelRecords are complete")

    return model, provider_record


async def lookup_model(
        model_name: FoundationModelHumanID,
        history_db: HistoryDB,
        audit_db: AuditDB,
) -> Tuple[FoundationModelRecordOrm, ProviderRecord]:
    try:
        return await lookup_model_offline(model_name, history_db)
    except (RuntimeError, ValueError, HTTPException):
        provider = ProviderRegistry().by_label[ProviderLabel(type="ollama", id=str(_real_ollama_client.base_url))]
        return await do_api_show(model_name, history_db, audit_db), await provider.make_record()


def fetch_model_record(
        executor_record: ProviderRecordOrm,
        model_name: FoundationModelHumanID,
        history_db: HistoryDB,
) -> FoundationModelRecordOrm | None:
    sorted_executor_info = dict(sorted(executor_record.identifiers.items()))

    return history_db.execute(
        select(FoundationModelRecordOrm)
        .where(FoundationModelRecordOrm.provider_identifiers == sorted_executor_info,
               FoundationModelRecordOrm.human_id == model_name)
        .order_by(FoundationModelRecordOrm.last_seen)
        .limit(1)
    ).scalar_one_or_none()
