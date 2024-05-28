from datetime import datetime
from typing import Generator

import orjson
from sqlalchemy import select, or_

from _util.json import safe_get
from history.ollama.json import OllamaResponseContentJSON
from providers.inference_models.database import HistoryDB
from providers.inference_models.orm import InferenceModelRecordOrm, InferenceModelRecord, \
    InferenceModelAddRequest, lookup_inference_model_detailed
from _util.typing import InferenceModelRecordID, InferenceModelHumanID
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
) -> Generator[InferenceModelRecord, None, None]:
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
            model_identifiers=sorted_model_json['details'],
            # combined_inference_parameters=None,
        )

        maybe_model = lookup_inference_model_detailed(model_in, history_db)
        if maybe_model is not None:
            maybe_model.merge_in_updates(model_in)
            history_db.add(maybe_model)
            history_db.commit()

            yield InferenceModelRecord.from_orm(maybe_model)
            continue

        # Also allow for the case where /api/show provided real parameters that got merged in
        maybe_model2 = history_db.execute(
            select(InferenceModelRecordOrm)
            .where(InferenceModelRecordOrm.human_id == model_in.human_id,
                   InferenceModelRecordOrm.provider_identifiers == model_in.provider_identifiers,
                   InferenceModelRecordOrm.model_identifiers == model_in.model_identifiers,
                   )
            .where(or_(
                InferenceModelRecordOrm.combined_inference_parameters.is_(None),
                InferenceModelRecordOrm.combined_inference_parameters.is_("null"),
            ))
            .order_by(InferenceModelRecordOrm.last_seen.desc())
            .limit(1)
        ).scalar_one_or_none()
        if maybe_model2 is not None:
            yield maybe_model2
            continue

        new_model = InferenceModelRecordOrm(
            **model_in.model_dump(),
        )
        history_db.add(new_model)
        history_db.commit()

        yield InferenceModelRecord.from_orm(new_model)


def build_model_from_api_show(
        human_id: InferenceModelHumanID,
        provider_identifiers: str,
        response_json: OllamaResponseContentJSON,
        history_db: HistoryDB,
) -> InferenceModelRecordOrm:
    sorted_response_json = orjson.loads(
        orjson.dumps(response_json, option=orjson.OPT_SORT_KEYS)
    )

    # Convert the 'details' key into model_identifiers
    model_identifiers = safe_get(sorted_response_json, "details") or {}

    # Parse the rest of the response into inference_parameters
    updated_inference_parameters = {}
    for k, v in sorted_response_json.items():
        if k == 'details':
            # Just skip it; should delete it, but "RuntimeError: dictionary changed size during iteration"
            continue

        elif k == 'parameters':
            # Apparently the list of parameters comes back in random order, so sort it
            sorted_params: list[str] = sorted(v.split('\n'))
            updated_inference_parameters[k] = '\n'.join(sorted_params)
            continue

        # And actually, the modelfile includes these out-of-order parameters, so just ignore eit
        elif k == 'modelfile':
            updated_inference_parameters[k] = "# no modelfile, ollama can't behave"
            continue

        updated_inference_parameters[k] = v

    # Construct most of a new model, for the sake of checking
    model_in = InferenceModelAddRequest(
        human_id=human_id,
        provider_identifiers=provider_identifiers,
        model_identifiers=model_identifiers,
        combined_inference_parameters=updated_inference_parameters,
    )

    # Quick check for more precise matches
    maybe_model1 = lookup_inference_model_detailed(model_in, history_db)
    if maybe_model1:
        return maybe_model1

    # Otherwise, scan entries one-at-a-time and figure out how to merge in data.
    # This merge is only feasible when /api/tags response and /api/show's 'details' sections are identical,
    # which only seems to be true testing a few models with `ollama --version` `0.1.33+e9ae607e`.
    #
    # Beyond that, though, it's not _terrible_ to have two sets of models, mapping to each call.
    maybe_model2 = history_db.execute(
        select(InferenceModelRecordOrm)
            .where(InferenceModelRecordOrm.human_id == model_in.human_id,
                   InferenceModelRecordOrm.provider_identifiers == model_in.provider_identifiers,
                   InferenceModelRecordOrm.model_identifiers == model_in.model_identifiers,
               )
        .where(or_(
            InferenceModelRecordOrm.combined_inference_parameters.is_(None),
            InferenceModelRecordOrm.combined_inference_parameters.is_("null"),
        ))
        .order_by(InferenceModelRecordOrm.last_seen.desc())
        .limit(1)
    ).scalar_one_or_none()
    if maybe_model2 is not None:
        maybe_model2.merge_in_updates(model_in)
        history_db.add(maybe_model2)
        history_db.commit()

        return maybe_model2

    # Otherwise-otherwise, just create an entirely new model
    new_model = InferenceModelRecordOrm(
        **model_in.model_dump(),
    )
    history_db.add(new_model)
    history_db.commit()

    return new_model
