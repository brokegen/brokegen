from typing import Optional

from fastapi import HTTPException
from pydantic import BaseModel
from sqlalchemy import select

from _util.typing import InferenceModelRecordID, ChatSequenceID
from client.database import ChatMessage, lookup_sequence_parents
from retrieval.embeddings.retrieval import RetrievalPolicyID
from providers.inference_models.database import HistoryDB
from providers.inference_models.orm import InferenceEventOrm, InferenceModelRecordOrm


class ContinueRequest(BaseModel):
    continuation_model_id: Optional[InferenceModelRecordID] = None
    fallback_model_id: Optional[InferenceModelRecordID] = None
    """Used in case the continuation is None, and also nothing recorded in ChatSequence history"""

    retrieval_policy: Optional[RetrievalPolicyID] = None
    retrieval_search_args: Optional[str] = None
    preferred_embedding_model: Optional[InferenceModelRecordID] = None


class ExtendRequest(BaseModel):
    next_message: ChatMessage
    continuation_model_id: Optional[InferenceModelRecordID] = None
    fallback_model_id: Optional[InferenceModelRecordID] = None

    retrieval_policy: Optional[RetrievalPolicyID] = None
    retrieval_search_args: Optional[str] = None
    preferred_embedding_model: Optional[InferenceModelRecordID] = None


def select_continuation_model(
        sequence_id: ChatSequenceID | None,
        requested_model_id: InferenceModelRecordID | None,
        fallback_model_id: InferenceModelRecordID | None,
        history_db: HistoryDB,
) -> InferenceEventOrm:
    if requested_model_id is not None:
        # TODO: Take this opportunity to confirm the InferenceModel is online.
        #       Though, maybe the inference events later on should be robust enough to handle errors.
        return history_db.execute(
            select(InferenceModelRecordOrm)
            .where(InferenceModelRecordOrm.id == requested_model_id)
        ).scalar_one()

    # Iterate over all sequence nodes until we find enough model info.
    # (ChatSequences can be missing inference_job_ids if they're user prompts, or errored out)
    for sequence in lookup_sequence_parents(sequence_id, history_db):
        if sequence.inference_job_id is None:
            continue

        inference_model: InferenceModelRecordOrm = history_db.execute(
            select(InferenceModelRecordOrm)
            .join(InferenceEventOrm, InferenceEventOrm.model_record_id == InferenceModelRecordOrm.id)
            .where(InferenceEventOrm.id == sequence.inference_job_id)
        ).scalar_one()

        return inference_model

    if fallback_model_id is not None:
        return history_db.execute(
            select(InferenceModelRecordOrm)
            .where(InferenceModelRecordOrm.id == fallback_model_id)
        ).scalar_one()

    raise HTTPException(400, f"Couldn't find any models ({requested_model_id=}, {fallback_model_id}, {sequence_id=})")
