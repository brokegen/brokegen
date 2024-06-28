import json
import logging
from datetime import datetime, timezone
from typing import Generator

import orjson
from sqlalchemy import select, or_, func

from _util.json import safe_get
from _util.typing import FoundationModelHumanID
from client.database import HistoryDB
from providers.inference_models.orm import FoundationModelRecordOrm, FoundationModelRecord, FoundationModelAddRequest, \
    lookup_foundation_model_detailed
from providers.orm import ProviderRecord
from providers_registry.ollama.api_chat.logging import OllamaResponseContentJSON

logger = logging.getLogger(__name__)


def build_models_from_api_tags(
        provider_record: ProviderRecord,
        accessed_at: datetime,
        response_json,
        history_db: HistoryDB,
) -> Generator[FoundationModelRecord, None, None]:
    """
    /api/tags fills in the `model_identifiers`, but `combined_inference_parameters` must be from /api/show
    """
    for model0 in safe_get(response_json, 'models'):
        sorted_model_json = orjson.loads(
            orjson.dumps(model0, option=orjson.OPT_SORT_KEYS)
        )

        # Construct most of a new model, for the sake of checking
        model_in = FoundationModelAddRequest(
            human_id=safe_get(sorted_model_json, 'name'),
            first_seen_at=accessed_at,
            last_seen=accessed_at,
            provider_identifiers=provider_record.identifiers,
            model_identifiers=sorted_model_json,
            combined_inference_parameters=None,
        )

        maybe_model = lookup_foundation_model_detailed(model_in, history_db)
        if maybe_model is not None:
            maybe_model.merge_in_updates(model_in)
            history_db.add(maybe_model)
            history_db.commit()

            yield FoundationModelRecord.from_orm(maybe_model)
            continue

        else:
            logger.info(f"GET /api/tags returned a new FoundationModelRecord: {safe_get(sorted_model_json, 'name')}")
            new_model = FoundationModelRecordOrm(**model_in.model_dump())
            history_db.add(new_model)
            history_db.commit()

            yield FoundationModelRecord.from_orm(new_model)
            continue


def build_model_from_api_show(
        human_id: FoundationModelHumanID,
        provider_identifiers: str,
        response_json: OllamaResponseContentJSON,
        history_db: HistoryDB,
) -> FoundationModelRecord:
    sorted_response_json = orjson.loads(
        orjson.dumps(response_json, option=orjson.OPT_SORT_KEYS)
    )

    # Parse the rest of the response into inference_parameters
    updated_inference_parameters = {}
    for k, v in sorted_response_json.items():
        if k == 'details':
            # Just skip it; should delete it, but "RuntimeError: dictionary changed size during iteration"
            continue

        elif k == 'parameters':
            final_ollama_parameters = {}

            # Apparently the list of parameters comes back in random order, so sort it
            sorted_ollama_parameter_lines: list[str] = sorted(v.split('\n'))
            for ollama_parameter_line in sorted_ollama_parameter_lines:
                try:
                    key, value = ollama_parameter_line.split(maxsplit=1)
                    if value and len(value) > 2:
                        # Remove leading and trailing quotation marks, for parameters that have spaces
                        value.strip('"')
                    final_ollama_parameters[key] = value

                except ValueError:
                    logger.error(f"Skipping Ollama parameter line for {human_id}: {ollama_parameter_line}")

            updated_inference_parameters[k] = final_ollama_parameters
            continue

        # And actually, the modelfile includes these out-of-order parameters, so just ignore eit
        elif k == 'modelfile':
            updated_inference_parameters[k] = \
                "# skipped modelfile contents, since ollama returns randomly-sorted parameters in it"
            continue

        updated_inference_parameters[k] = v

    # Construct most of a new model, for the sake of checking
    model_in = FoundationModelAddRequest(
        human_id=human_id,
        last_seen=datetime.now(tz=timezone.utc),
        provider_identifiers=provider_identifiers,
        combined_inference_parameters=updated_inference_parameters,
    )

    parent_model_id = safe_get(sorted_response_json, "details", "parent_model")
    if parent_model_id:
        # Noticed starting with Ollama 0.1.33+e9ae607e
        logger.warning(
            f"ollama /api/show: Erasing parent_model info, because it's inconsistent: {parent_model_id} => {human_id}")
        sorted_response_json["details"]["parent_model"] = ""

    # reference_model_details = orjson.dumps(safe_get(sorted_response_json, "details")).decode()
    reference_model_details: str = json.dumps(safe_get(sorted_response_json, "details"), separators=(',', ':'))
    """In particular, sqlalchemy.func.json_extract() returns a _string_, while orjson is bytes."""

    # Check for an exact match first, which should be the most common case
    exact_match: FoundationModelRecordOrm | None = history_db.execute(
        select(FoundationModelRecordOrm)
        .where(
            FoundationModelRecordOrm.human_id == human_id,
            FoundationModelRecordOrm.provider_identifiers == provider_identifiers,
            func.json_extract(FoundationModelRecordOrm.model_identifiers, "$.details") == reference_model_details,
            FoundationModelRecordOrm.combined_inference_parameters == updated_inference_parameters,
        )
        .order_by(FoundationModelRecordOrm.last_seen.desc())
        .limit(1)
    ).scalar_one_or_none()
    if exact_match is not None:
        exact_match.merge_in_updates(model_in)
        history_db.add(exact_match)
        history_db.commit()

        return FoundationModelRecord.from_orm(exact_match)

    # Scan for /api/tags-created entries one-at-a-time and figure out how to merge in data.
    # This merge is only feasible when /api/tags response and /api/show's 'details' sections are identical,
    # which seems to be true testing a few models with `ollama --version` `0.1.33+e9ae607e`.
    api_tags_match: FoundationModelRecordOrm | None = history_db.execute(
        select(FoundationModelRecordOrm)
        .where(
            FoundationModelRecordOrm.human_id == human_id,
            FoundationModelRecordOrm.provider_identifiers == provider_identifiers,
            func.json_extract(FoundationModelRecordOrm.model_identifiers, "$.details") == reference_model_details,
            or_(
                FoundationModelRecordOrm.combined_inference_parameters.is_(None),
                FoundationModelRecordOrm.combined_inference_parameters.is_("null"),
            ),
        )
        .order_by(FoundationModelRecordOrm.last_seen.desc())
        .limit(1)
    ).scalar_one_or_none()
    if api_tags_match is not None:
        api_tags_match.merge_in_updates(model_in)
        history_db.add(api_tags_match)
        history_db.commit()

        return FoundationModelRecord.from_orm(api_tags_match)

    raise RuntimeError(
        f"Could not process {human_id}, try calling /api/tags first before populating its inference parameters")
