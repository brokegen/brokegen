import json
from datetime import datetime
from typing import Generator

import orjson
from sqlalchemy import select, func

from _util.json import safe_get
from history.ollama.json import OllamaResponseContentJSON
from providers.inference_models.database import HistoryDB, get_db
from providers.inference_models.orm import InferenceModelRecordOrm, InferenceModelRecordID, InferenceModelRecord, \
    InferenceModelAddRequest, lookup_inference_model_record_detailed
from providers.orm import ProviderRecordOrm, ProviderRecord


def fetch_model_record(
        executor_record: ProviderRecordOrm,
        model_name: str,
        history_db: HistoryDB,
) -> InferenceModelRecordOrm | None:
    sorted_executor_info = dict(sorted(executor_record.identifiers.items()))

    return history_db.execute(
        select(InferenceModelRecordOrm)
        .where(InferenceModelRecordOrm.provider_identifiers == sorted_executor_info,
               InferenceModelRecordOrm.human_id == model_name)
        .order_by(InferenceModelRecordOrm.last_seen)
        .limit(1)
    ).scalar_one_or_none()


def build_models_from_api_tags(
        provider_record: ProviderRecord,
        accessed_at: datetime,
        response_json,
        history_db: HistoryDB,
) -> Generator[tuple[InferenceModelRecordID, InferenceModelRecord], None, None]:
    for model0 in safe_get(response_json, 'models'):
        sorted_model_json = orjson.loads(
            orjson.dumps(model0, option=orjson.OPT_SORT_KEYS)
        )

        model_modified_at = accessed_at
        if safe_get(sorted_model_json, 'modified_at'):
            # TODO: Verify whether ollama source timestamps are in UTC
            model_modified_at = datetime.fromisoformat(sorted_model_json['modified_at'])
            model_modified_at = model_modified_at.replace(tzinfo=None)

        # Construct most of a new model, for the sake of checking
        model_in = InferenceModelAddRequest(
            human_id=safe_get(sorted_model_json, 'name'),
            first_seen_at=model_modified_at,
            last_seen=model_modified_at,
            provider_identifiers=provider_record.identifiers,
            model_identifiers=orjson.dumps(sorted_model_json['details'], option=orjson.OPT_SORT_KEYS),
            # combined_inference_parameters=None,
        )

        maybe_model = lookup_inference_model_record_detailed(model_in, history_db)
        if maybe_model is not None:
            maybe_model.merge_in_updates(model_in)
            history_db.add(maybe_model)
            history_db.commit()

            yield maybe_model.id, InferenceModelRecord.from_orm(maybe_model)
            continue

        new_model = InferenceModelRecordOrm(
            **model_in.model_dump(),
        )
        history_db.add(new_model)
        history_db.commit()

        yield new_model.id, InferenceModelRecord.from_orm(new_model)


def build_model_from_api_show(
        executor_record: ProviderRecordOrm,
        human_id: str,
        accessed_at: datetime,
        response_json: OllamaResponseContentJSON,
        do_commit: bool = True,
        history_db: HistoryDB | None = None,
) -> InferenceModelRecordOrm:
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
            func.json_extract(InferenceConfigRecordOrm.model_identifiers, "$.details")
            # TODO: Figure out how this works with orjson
            == json.dumps(static_model_info['details'], separators=(',', ':'), sort_keys=True)
    )
    maybe_model = history_db.execute(
        select(InferenceConfigRecordOrm)
        .where(
            InferenceConfigRecordOrm.human_id == human_id,
            InferenceConfigRecordOrm.provider_identifiers == sorted_executor_info,
            details_match_statement,
            InferenceConfigRecordOrm.combined_inference_parameters == default_inference_params,
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
        select(InferenceConfigRecordOrm)
        .where(
            InferenceConfigRecordOrm.human_id == human_id,
            InferenceConfigRecordOrm.provider_identifiers == sorted_executor_info,
            details_match_statement,
            InferenceConfigRecordOrm.combined_inference_parameters.is_({}),
        )
    ).scalar_one_or_none()
    if maybe_api_tags_model is not None:
        maybe_api_tags_model.first_seen_at = min(maybe_api_tags_model.first_seen_at, accessed_at)
        maybe_api_tags_model.last_seen = max(maybe_api_tags_model.last_seen, accessed_at)
        maybe_api_tags_model.combined_inference_parameters = default_inference_params

        history_db.add(maybe_api_tags_model)
        if do_commit:
            history_db.commit()

        return maybe_api_tags_model

    new_model = InferenceConfigRecordOrm(
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
