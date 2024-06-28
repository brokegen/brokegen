from typing import Optional

from fastapi import HTTPException
from pydantic import BaseModel
from sqlalchemy import select

from _util.typing import FoundationModelRecordID, ChatSequenceID
from client.message import ChatMessage
from client.database import HistoryDB
from providers.inference_models.orm import InferenceEventOrm, FoundationModelRecordOrm
from providers.registry import InferenceOptions
from retrieval.faiss.retrieval import RetrievalLabel


class AutonamingOptions(BaseModel):
    autonaming_policy: Optional[str] = None
    preferred_autonaming_model: Optional[FoundationModelRecordID] = None


class ContinueRequest(InferenceOptions, RetrievalLabel, AutonamingOptions):
    continuation_model_id: Optional[FoundationModelRecordID] = None
    fallback_model_id: Optional[FoundationModelRecordID] = None
    """Used in case the continuation_model_id is None, and also nothing recorded in ChatSequence history"""


class ExtendRequest(ContinueRequest):
    next_message: ChatMessage


def select_continuation_model(
        sequence_id: ChatSequenceID | None,
        requested_model_id: FoundationModelRecordID | None,
        fallback_model_id: FoundationModelRecordID | None,
        history_db: HistoryDB,
) -> InferenceEventOrm:
    if requested_model_id is not None:
        # TODO: Take this opportunity to confirm the InferenceModel is online.
        #       Though, maybe the inference events later on should be robust enough to handle errors.
        return history_db.execute(
            select(FoundationModelRecordOrm)
            .where(FoundationModelRecordOrm.id == requested_model_id)
        ).scalar_one()

    # Iterate over all sequence nodes until we find enough model info.
    # (ChatSequences can be missing inference_job_ids if they're user prompts, or errored out)
    #
    # TODO: circular import
    from client.chat_sequence import lookup_sequence_parents

    for sequence in lookup_sequence_parents(sequence_id, history_db):
        if sequence.inference_job_id is None:
            continue

        inference_model: FoundationModelRecordOrm = history_db.execute(
            select(FoundationModelRecordOrm)
            .join(InferenceEventOrm, InferenceEventOrm.model_record_id == FoundationModelRecordOrm.id)
            .where(InferenceEventOrm.id == sequence.inference_job_id)
        ).scalar_one()

        return inference_model

    if fallback_model_id is not None:
        return history_db.execute(
            select(FoundationModelRecordOrm)
            .where(FoundationModelRecordOrm.id == fallback_model_id)
        ).scalar_one()

    raise HTTPException(400, f"Couldn't find any models ({requested_model_id=}, {fallback_model_id}, {sequence_id=})")
