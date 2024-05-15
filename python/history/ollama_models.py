import json
import platform
import uuid
from datetime import datetime, timezone

from sqlalchemy import select, func

from history.database import HistoryDB, ModelConfigRecord, get_db, ExecutorConfigRecord


def build_executor_record(
        endpoint: str,
        do_commit: bool = True,
        history_db: HistoryDB | None = None,
) -> ExecutorConfigRecord:
    if history_db is None:
        history_db = next(get_db())

    executor_info = {
        'name': "ollama",
        'endpoint': endpoint,
        'platform': platform.platform(),
        # https://docs.python.org/3/library/uuid.html#uuid.getnode
        # This is based on the MAC address of a network interface on the host system;the important
        # thing is that the ProviderConfigRecord differs when the setup might give different results.
        'node-id': uuid.getnode(),
    }

    maybe_executor = history_db.execute(
        select(ExecutorConfigRecord)
        .where(ExecutorConfigRecord.executor_info == executor_info)
    ).scalar_one_or_none()
    if maybe_executor is not None:
        return maybe_executor

    new_executor = ExecutorConfigRecord(
        executor_info=executor_info,
        created_at=datetime.now(tz=timezone.utc),
    )
    history_db.add(new_executor)
    if do_commit:
        history_db.commit()

    return new_executor


def build_model_from_api_show(
        executor_record: ExecutorConfigRecord,
        human_id: str,
        accessed_at: datetime,
        response_json,
        do_commit: bool = True,
        history_db: HistoryDB | None = None,
) -> ModelConfigRecord:
    if history_db is None:
        history_db = next(get_db())

    static_model_info = {
        'details': response_json['details'],
    }

    # Copy everything except 'details' into the inference parameters
    default_inference_params = dict(response_json)
    del default_inference_params['details']

    # First, check for exact matches.
    #
    # - NB SQLite JSON uses a compact encoding, so we have to strip extra whitespace from our result.
    # - Also, note that we sort the fields later on, to ensure consistency
    details_match_statement = (
            func.json_extract(ModelConfigRecord.static_model_info, "$.details")
            == json.dumps(static_model_info['details'], separators=(',', ':'))
    )
    maybe_model = history_db.execute(
        select(ModelConfigRecord)
        .where(
            ModelConfigRecord.human_id == human_id,
            ModelConfigRecord.executor_info == executor_record.executor_info,
            details_match_statement,
            ModelConfigRecord.default_inference_params == default_inference_params,
        )
    ).scalar_one_or_none()
    if maybe_model is not None:
        maybe_model.first_seen_at = min(maybe_model.first_seen_at, accessed_at)
        maybe_model.last_seen = max(maybe_model.last_seen, accessed_at)

        history_db.add(maybe_model)
        if do_commit:
            history_db.commit()

        return maybe_model

    # Next, check for things maybe returned from /api/tags
    maybe_api_tags_model = history_db.execute(
        select(ModelConfigRecord)
        .where(
            ModelConfigRecord.human_id == human_id,
            ModelConfigRecord.executor_info == executor_record.executor_info,
            details_match_statement,
            ModelConfigRecord.default_inference_params.is_(None),
        )
    ).scalar_one_or_none()
    if maybe_api_tags_model is not None:
        maybe_api_tags_model.first_seen_at = min(maybe_api_tags_model.first_seen_at, accessed_at)
        maybe_api_tags_model.last_seen = max(maybe_api_tags_model.last_seen, accessed_at)
        maybe_api_tags_model.default_inference_params = default_inference_params

        history_db.add(maybe_api_tags_model)
        if do_commit:
            history_db.commit()

        return maybe_api_tags_model

    new_model = ModelConfigRecord(
        human_id=human_id,
        first_seen_at=accessed_at,
        last_seen=accessed_at,
        executor_info=executor_record.executor_info,
        static_model_info=static_model_info,
        default_inference_params=default_inference_params,
    )
    history_db.add(new_model)
    if do_commit:
        history_db.commit()

    return new_model
