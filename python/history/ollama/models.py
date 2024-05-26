import json
from datetime import datetime

import orjson
from sqlalchemy import select, func

from history.ollama.json import OllamaResponseContentJSON
from providers.database import HistoryDB, ModelConfigRecord, get_db, ProviderRecordOrm


def fetch_model_record(
        executor_record: ProviderRecordOrm,
        model_name: str,
        history_db: HistoryDB,
) -> ModelConfigRecord | None:
    sorted_executor_info = dict(sorted(executor_record.identifiers.items()))

    return history_db.execute(
        select(ModelConfigRecord)
        .where(ModelConfigRecord.provider_identifiers == sorted_executor_info,
               ModelConfigRecord.human_id == model_name)
        .order_by(ModelConfigRecord.last_seen)
        .limit(1)
    ).scalar_one_or_none()


def build_models_from_api_tags(
        executor_record: ProviderRecordOrm,
        accessed_at: datetime,
        response_json,
        do_commit: bool = True,
        history_db: HistoryDB | None = None,
) -> None:
    if history_db is None:
        history_db = next(get_db())

    for model in response_json['models']:
        sorted_model_json = orjson.loads(
            orjson.dumps(model, option=orjson.OPT_SORT_KEYS)
        )
        sorted_executor_info = dict(sorted(executor_record.identifiers.items()))
        modified_at = datetime.fromisoformat(sorted_model_json['modified_at'])
        # TODO: Verify whether ollama source timestamps are in UTC
        modified_at = modified_at.replace(tzinfo=None)

        # First, check for exact matches.
        details_match_statement = (
                func.json_extract(ModelConfigRecord.static_model_info, "$.details")
                == json.dumps(sorted_model_json['details'], separators=(',', ':'), sort_keys=True)
        )
        maybe_model = history_db.execute(
            select(ModelConfigRecord)
            .where(
                ModelConfigRecord.human_id == sorted_model_json['name'],
                ModelConfigRecord.provider_identifiers == sorted_executor_info,
                details_match_statement,
            )
            .order_by(ModelConfigRecord.last_seen.desc())
            .limit(1)
        ).scalar_one_or_none()
        if maybe_model is not None:
            # If we already have a record, check dates to see if we expect modification
            if modified_at <= maybe_model.last_seen:
                # Everything's good and matches, just update its static info, which is all we have anyway
                # TODO: That `modified_at` field would be really nice to have, somewhere else
                maybe_model.static_model_info = sorted_model_json
                maybe_model.first_seen_at = min(maybe_model.first_seen_at, accessed_at, modified_at)
                maybe_model.last_seen = max(maybe_model.last_seen, accessed_at, modified_at)

                history_db.add(maybe_model)
                if do_commit:
                    history_db.commit()

                continue

        # Otherwise, what is all this, just add a new thing
        new_model = ModelConfigRecord(
            human_id=sorted_model_json['name'],
            first_seen_at=modified_at,
            last_seen=max(modified_at, accessed_at),
            executor_info=executor_record.identifiers,
            static_model_info=sorted_model_json,
            default_inference_params={},
        )

        history_db.add(new_model)
        if do_commit:
            history_db.commit()


def build_model_from_api_show(
        executor_record: ProviderRecordOrm,
        human_id: str,
        accessed_at: datetime,
        response_json: OllamaResponseContentJSON,
        do_commit: bool = True,
        history_db: HistoryDB | None = None,
) -> ModelConfigRecord:
    if history_db is None:
        history_db = next(get_db())

    sorted_response_json = orjson.loads(
        orjson.dumps(response_json, option=orjson.OPT_SORT_KEYS)
    )
    sorted_executor_info = dict(sorted(executor_record.identifiers.items()))

    static_model_info = {}
    default_inference_params = {}

    # Copy everything except 'details' into the inference parameters
    for k, v in sorted_response_json.items():
        if k == 'details':
            static_model_info['details'] = v
            continue

        elif k == 'parameters':
            # Apparently the list of parameters comes back in random order
            sorted_params: list[str] = sorted(v.split('\n'))
            default_inference_params[k] = '\n'.join(sorted_params)
            continue

        # And actually, the modelfile includes these out-of-order parameters
        elif k == 'modelfile':
            default_inference_params[k] = "# no modelfile, ollama can't behave"
            continue

        default_inference_params[k] = v

    # First, check for exact matches.
    #
    # - NB SQLite JSON uses a compact encoding, so we have to strip extra whitespace from our result.
    # - Also, note that we sort the fields later on, to ensure consistency
    details_match_statement = (
            func.json_extract(ModelConfigRecord.static_model_info, "$.details")
            # TODO: Figure out how this works with orjson
            == json.dumps(static_model_info['details'], separators=(',', ':'), sort_keys=True)
    )
    maybe_model = history_db.execute(
        select(ModelConfigRecord)
        .where(
            ModelConfigRecord.human_id == human_id,
            ModelConfigRecord.provider_identifiers == sorted_executor_info,
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
    # TODO: This gets weird with writing params here and there;
    #       need to formalize this with unit tests.
    maybe_api_tags_model = history_db.execute(
        select(ModelConfigRecord)
        .where(
            ModelConfigRecord.human_id == human_id,
            ModelConfigRecord.provider_identifiers == sorted_executor_info,
            details_match_statement,
            ModelConfigRecord.default_inference_params.is_({}),
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
        executor_info=executor_record.identifiers,
        static_model_info=static_model_info,
        default_inference_params=default_inference_params,
    )
    history_db.add(new_model)
    if do_commit:
        history_db.commit()

    return new_model
