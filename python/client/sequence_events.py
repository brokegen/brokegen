from datetime import datetime
from typing import Optional

import fastapi
import orjson
from fastapi import Depends
from pydantic import BaseModel, Json
from sqlalchemy import select

from _util.json import safe_get
from _util.typing import FoundationModelRecordID, ChatSequenceID
from client.database import HistoryDB, get_db as get_history_db
from providers.inference_models.orm import InferenceEventOrm, InferenceReason, InferenceEventID


class InferenceEventIn(BaseModel):
    prompt_tokens: Optional[int] = None
    prompt_eval_time: Optional[float] = None
    prompt_with_templating: Optional[str] = None

    response_created_at: Optional[datetime] = None
    response_tokens: Optional[int] = None
    response_eval_time: Optional[float] = None

    response_error: Optional[str] = None
    response_info: Optional[Json] = None
    response_info_str: Optional[str] = None
    """
    Included for legacy reasons, aka can't figure out how to get client to encode the JSON correctly.
    """

    parent_sequence: Optional[ChatSequenceID] = None
    reason: Optional[InferenceReason] = None


class InferenceEventAddResponse(BaseModel):
    ijob_id: InferenceEventID
    just_created: bool


def install_routes(router_ish: fastapi.FastAPI | fastapi.routing.APIRouter) -> None:
    @router_ish.post("/models/{model_record_id:int}/inference-events")
    def construct_inference_event(
            response: fastapi.Response,
            model_record_id: FoundationModelRecordID,
            inference_event_in: InferenceEventIn,
            history_db: HistoryDB = Depends(get_history_db),
    ) -> InferenceEventAddResponse:
        # Check for matches
        filtered_inference_event_in = {
            "model_record_id": model_record_id,
        }
        for k, v in inference_event_in.model_dump().items():
            # SQL NULL always compares not equal, so skip those items
            if v:
                filtered_inference_event_in[k] = v

        if "response_info_str" in filtered_inference_event_in:
            if not filtered_inference_event_in.get("response_info", None):
                # Enforce response_info sort order
                sorted_response_info = orjson.loads(
                    orjson.dumps(
                        orjson.loads(filtered_inference_event_in["response_info_str"]),
                        option=orjson.OPT_SORT_KEYS
                    )
                )
                filtered_inference_event_in["response_info"] = sorted_response_info
                del filtered_inference_event_in["response_info_str"]

        match_object = history_db.execute(
            select(InferenceEventOrm.id)
            .filter_by(**filtered_inference_event_in)
        ).scalar_one_or_none()
        if match_object is not None:
            return InferenceEventAddResponse(
                ijob_id=match_object,
                just_created=False,
            )

        if not safe_get(filtered_inference_event_in, "reason"):
            filtered_inference_event_in["reason"] = "[api import]"

        new_object = InferenceEventOrm(**filtered_inference_event_in)
        history_db.add(new_object)
        history_db.commit()

        response.status_code = fastapi.status.HTTP_201_CREATED
        return InferenceEventAddResponse(
            ijob_id=new_object.id,
            just_created=True,
        )
