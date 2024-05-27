from datetime import datetime
from typing import TypeAlias, Optional, Self

from pydantic import PositiveInt, BaseModel, ConfigDict
from sqlalchemy import Column, Integer, String, DateTime, JSON, Double, select, UniqueConstraint

from _util.typing import ChatSequenceID
from inference.prompting.models import TemplatedPromptText
from providers.inference_models.database import Base, HistoryDB
from providers.orm import ProviderLabel

InferenceModelRecordID: TypeAlias = PositiveInt
InferenceModelHumanID: TypeAlias = str

InferenceEventID: TypeAlias = PositiveInt
InferenceReason: TypeAlias = str
"""TODO: Should be an enum, but enums for SQLAlchemy take some work"""


class InferenceModelLabel(BaseModel):
    provider: ProviderLabel
    human_id: InferenceModelHumanID

    model_config = ConfigDict(
        extra='forbid',
        frozen=True,
    )


class InferenceModelRecord(BaseModel):
    id: InferenceModelRecordID
    human_id: InferenceModelHumanID

    first_seen_at: Optional[datetime] = None
    last_seen: Optional[datetime] = None

    provider_identifiers: str
    model_identifiers: Optional[dict] = None

    combined_inference_parameters: Optional[dict] = None

    model_config = ConfigDict(
        extra='forbid',
        from_attributes=True,
        frozen=True,
    )


class InferenceModelAddRequest(BaseModel):
    """
    TODO: This should really inherit from the normal Record class, but:

    - frozen=True needs to get unset
    - provider_identifiers should be nullable, since model requests always come with Provider.identifiers
    """
    human_id: InferenceModelHumanID

    first_seen_at: Optional[datetime] = None
    last_seen: Optional[datetime] = None

    provider_identifiers: Optional[str] = None
    """WARNING: This field is generally not-sorted, and should be, for realistic use."""
    model_identifiers: Optional[dict] = None

    combined_inference_parameters: Optional[dict] = None


class InferenceModelRecordOrm(Base):
    __tablename__ = 'InferenceModelRecords'

    id: InferenceModelRecordID = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    human_id: InferenceModelHumanID = Column(String, nullable=False)

    first_seen_at = Column(DateTime)
    last_seen = Column(DateTime)

    # TODO: ForeignKey('ProviderRecords.identifiers')
    provider_identifiers: str = Column(String, nullable=False)
    model_identifiers = Column(JSON)
    """
    Contains parameters that are not something our client can change,
    e.g. if user updated/created a new ollama model that reuses the same `human_id`.

    This can be surfaced to the end user, but since it's virtually inactionable,
    should be shown differently.
    """

    combined_inference_parameters = Column(JSON)
    """
    Parameters that can be overridden at "runtime", i.e. by individual message calls.
    If these change, they are likely to be intentional and temporary changes, e.g.:

    - intentional: the client overrides the system prompt
    - intentional: the set of stop tokens changes for a different prompt type
    - temporary: the temperature used for inference is being prompt-engineered by DSPy

    These will be important to surface to the user, but that's _because_ they were
    assumed to be changed in response to user actions.
    """

    __table_args__ = (
        UniqueConstraint("human_id", "provider_identifiers", "model_identifiers", "combined_inference_parameters",
                         name="all columns"),
    )

    def merge_in_updates(self, model_in: InferenceModelRecord | InferenceModelAddRequest) -> Self:
        # Update the last-seen date, if needed
        if model_in.first_seen_at is not None:
            if self.first_seen_at is None:
                self.first_seen_at = model_in.first_seen_at
            else:
                self.first_seen_at = min(model_in.first_seen_at, self.first_seen_at)
        if model_in.last_seen is not None:
            if self.last_seen is None:
                self.last_seen = model_in.last_seen
            else:
                self.last_seen = min(model_in.last_seen, self.last_seen)

        if not self.model_identifiers or self.model_identifiers == 'null':
            self.model_identifiers = model_in.model_identifiers

        if not self.combined_inference_parameters or self.combined_inference_parameters == 'null':
            self.combined_inference_parameters = model_in.combined_inference_parameters

        return self

    def as_json(self):
        cols = InferenceModelRecordOrm.__mapper__.columns
        return dict([
            (col.name, getattr(self, col.name)) for col in cols
        ])


def lookup_inference_model_record(
        human_id: InferenceModelHumanID,
        provider_identifiers: str,
        history_db: HistoryDB,
) -> InferenceModelRecordOrm:
    return history_db.execute(
        select(InferenceModelRecordOrm)
        .where(InferenceModelRecordOrm.provider_identifiers == provider_identifiers,
               InferenceModelRecordOrm.human_id == human_id)
        .order_by(InferenceModelRecordOrm.last_seen.desc())
        .limit(1)
    ).scalar_one()


def lookup_inference_model_record_detailed(
        model_in: InferenceModelAddRequest,
        history_db: HistoryDB,
) -> InferenceModelRecordOrm | None:
    where_clauses = [
        InferenceModelRecordOrm.human_id == model_in.human_id,
        InferenceModelRecordOrm.provider_identifiers == model_in.provider_identifiers,
    ]
    # NULL will always return not equal in SQL, so check only if there's something to check
    if model_in.model_identifiers:
        where_clauses.append(InferenceModelRecordOrm.model_identifiers == model_in.model_identifiers)
    if model_in.combined_inference_parameters:
        where_clauses.append(
            InferenceModelRecordOrm.combined_inference_parameters == model_in.combined_inference_parameters)

    return history_db.execute(
        select(InferenceModelRecordOrm)
        .where(*where_clauses)
    ).scalar_one_or_none()


class InferenceEventOrm(Base):
    """
    These are basically 1:1 with ChatSequences, though sub-queries will also generate these.

    Primary purpose of these records is estimating tokens/second, or extrapolating time/money costs
    for having a different executor do the inference.
    """
    __tablename__ = 'InferenceEvents'

    id: InferenceEventID = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    model_record_id: InferenceModelRecordID = Column(Integer, nullable=False)

    prompt_tokens = Column(Integer)
    prompt_eval_time = Column(Double)
    """
    Total time in seconds (Apple documentation for timeIntervalSince uses seconds, so why not)
    Equivalent to "time to first token."
    """
    prompt_with_templating: TemplatedPromptText | None = Column(String, nullable=True)
    """
    Can explicitly be NULL, in which case
    we should have enough info across other tables to reconstruct the \"raw\" prompt
    """

    response_created_at = Column(DateTime)
    response_tokens = Column(Integer)
    response_eval_time = Column(Double)
    "Total time in seconds"

    response_error = Column(String)
    "If this field is non-NULL, indicates that an error occurred during inference"
    response_info = Column(JSON)
    """
    Freeform field, for additional data from the Provider.
    """

    parent_sequence: ChatSequenceID = Column(Integer)
    """
    Useful for collating information across several inference jobs, to determine \"actual\" cost of a query
    """
    reason: InferenceReason = Column(String)
    """
    Should be an enum, but open-ended.
    
    Planned types:

    - `prompt` means it was the direct/final user prompt, maybe handled with manual templating
    - `prompt+rag` means extra context added to the user prompt,
       check for other InferenceEvents with the same `parent_sequence`
    - `summarize prompt for retrieval` means a given prompt seemed too long/complex, summarize (or split it) for retrieval
    - `summarize document` means a retrieval doc was too long, we made another query to summarize that
    - `summarize chat` means there were too many tokens provided for the requested context window size
    """

    __table_args__ = (
        UniqueConstraint("model_record_id", "prompt_tokens", "prompt_eval_time", "prompt_with_templating",
                         "response_created_at", "response_tokens", "response_eval_time", "response_error",
                         "response_info", name="stats columns"),
    )


def lookup_inference_model(
        inference_id: InferenceEventID,
        history_db: HistoryDB,
) -> InferenceModelRecordOrm | None:
    return history_db.execute(
        select(InferenceModelRecordOrm)
        .join(InferenceEventOrm, InferenceEventOrm.model_record_id == InferenceModelRecordOrm.id)
        .where(InferenceEventOrm.id == inference_id)
    ).scalar_one_or_none()
