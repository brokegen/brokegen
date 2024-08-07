import logging
from datetime import datetime, timezone, timedelta
from typing import TypeAlias, Optional, Self, Iterable, Any

from pydantic import PositiveInt, BaseModel, ConfigDict
from sqlalchemy import Column, Integer, String, DateTime, JSON, Double, select, UniqueConstraint, func, or_

from _util.typing import ChatSequenceID, TemplatedPromptText, FoundationModelRecordID, FoundationModelHumanID, \
    InferenceReason
from client.database import Base, HistoryDB
from providers.orm import ProviderLabel, ProviderType, ProviderID

InferenceEventID: TypeAlias = PositiveInt

logger = logging.getLogger(__name__)


class FoundationModelLabel(BaseModel):
    provider: ProviderLabel
    human_id: FoundationModelHumanID

    model_config = ConfigDict(
        extra='forbid',
        frozen=True,
    )


class FoundationModelRecord(BaseModel):
    id: FoundationModelRecordID
    human_id: FoundationModelHumanID

    first_seen_at: Optional[datetime] = None
    last_seen: Optional[datetime] = None

    provider_type: Optional[ProviderType] = None
    provider_id: Optional[ProviderID] = None
    provider_identifiers: str
    model_identifiers: Optional[dict] = None

    combined_inference_parameters: Optional[dict] = None

    model_config = ConfigDict(
        extra='forbid',
        from_attributes=True,
        frozen=True,
        protected_namespaces=(),
    )


class FoundationModelResponse(FoundationModelRecord):
    display_stats: Optional[dict] = None
    all_stats: Optional[dict[str, float]] = None

    label: ProviderLabel
    available: Optional[bool] = None

    latest_inference_event: Optional[datetime] = None
    recent_inference_events: int = 0
    recent_tokens_per_second: float = 0.0

    model_config = ConfigDict(
        extra='allow',
        frozen=False,
    )


class FoundationModelAddRequest(BaseModel):
    """
    TODO: This should really inherit from the normal Record class, but:

    - frozen=True needs to get unset
    - provider_identifiers should be nullable, since model requests always come with Provider.identifiers
    """
    human_id: FoundationModelHumanID

    first_seen_at: Optional[datetime] = None
    last_seen: Optional[datetime] = None

    provider_identifiers: Optional[str] = None
    """WARNING: This field is generally not-sorted, and should be, for realistic use."""
    model_identifiers: Optional[dict] = None

    combined_inference_parameters: Optional[dict] = None

    model_config = ConfigDict(
        protected_namespaces=(),
    )


class FoundationModelRecordOrm(Base):
    __tablename__ = 'InferenceModelRecords'

    id: FoundationModelRecordID = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    human_id: FoundationModelHumanID = Column(String, nullable=False)

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

    Notes:

    * the system prompt is basically ignored, since it could change per-request and doesn't impact inference
    """

    __table_args__ = (
        UniqueConstraint("human_id", "provider_identifiers", "model_identifiers", "combined_inference_parameters",
                         name="all columns"),
    )

    def __str__(self):
        return f"<FoundationModelRecordOrm#{self.id} human_id={self.human_id}>"

    def merge_in_updates(self, model_in: FoundationModelRecord | FoundationModelAddRequest) -> Self:
        # Update the last-seen date, if needed
        if model_in.first_seen_at is not None:
            if self.first_seen_at is None:
                self.first_seen_at = model_in.first_seen_at
            else:
                requested_first_seen = model_in.first_seen_at.replace(tzinfo=None)
                self.first_seen_at = min(requested_first_seen, self.first_seen_at)
        if model_in.last_seen is not None:
            if self.last_seen is None:
                self.last_seen = model_in.last_seen
            else:
                # SQL results are naive datetimes?
                requested_last_seen = model_in.last_seen.replace(tzinfo=None)
                self.last_seen = max(requested_last_seen, self.last_seen)

        if not self.model_identifiers or self.model_identifiers == 'null':
            self.model_identifiers = model_in.model_identifiers

        if not self.combined_inference_parameters or self.combined_inference_parameters == 'null':
            self.combined_inference_parameters = model_in.combined_inference_parameters

        return self

    def model_dump(self) -> Iterable[tuple[str, Any]]:
        for column in FoundationModelRecordOrm.__mapper__.columns:
            yield column.name, getattr(self, column.name)


def lookup_foundation_model(
        human_id: FoundationModelHumanID,
        provider_identifiers: str,
        history_db: HistoryDB,
) -> FoundationModelRecordOrm:
    return history_db.execute(
        select(FoundationModelRecordOrm)
        .where(FoundationModelRecordOrm.provider_identifiers == provider_identifiers,
               FoundationModelRecordOrm.human_id == human_id)
        .order_by(FoundationModelRecordOrm.last_seen.desc())
        .limit(1)
    ).scalar_one_or_none()


def lookup_foundation_model_detailed(
        model_in: FoundationModelAddRequest,
        history_db: HistoryDB,
) -> FoundationModelRecordOrm | None:
    where_clauses = [
        FoundationModelRecordOrm.human_id == model_in.human_id,
        FoundationModelRecordOrm.provider_identifiers == model_in.provider_identifiers,
    ]
    # NULL will always return not equal in SQL, so check only if there's something to check
    if model_in.model_identifiers:
        where_clauses.append(FoundationModelRecordOrm.model_identifiers == model_in.model_identifiers)
    if model_in.combined_inference_parameters:
        where_clauses.append(
            FoundationModelRecordOrm.combined_inference_parameters == model_in.combined_inference_parameters)

    return history_db.execute(
        select(FoundationModelRecordOrm)
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
    model_record_id: FoundationModelRecordID = Column(Integer, nullable=False)

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

    response_created_at = Column(DateTime, nullable=False)
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
    Useful for collating information across several inference jobs, to determine \"actual\" cost of a query.
    Note that this is a circular reference, so is usually set in a second pass.

    TODO: Use SQLAlchemy correctly and set it in one pass.
    """
    reason: InferenceReason = Column(String)
    """
    Should be an enum, but open-ended.

    Planned types:

    - `prompt` means it was the direct/final user prompt, maybe handled with manual templating
    - `prompt+rag` means extra context added to the user prompt,
       check for other InferenceEvents with the same `parent_sequence`
    - `chat` means we passed in messages (with role + content like OpenAI's final API endpoint)
    - `summarize prompt for retrieval` means a given prompt seemed too long/complex, summarize (or split it) for retrieval
    - `summarize document` means a retrieval doc was too long, we made another query to summarize that
    - `summarize chat` means there were too many tokens provided for the requested context window size
    """

    __table_args__ = (
        UniqueConstraint("model_record_id", "prompt_tokens", "prompt_eval_time", "prompt_with_templating",
                         "response_created_at", "response_tokens", "response_eval_time", "response_error",
                         "response_info", name="stats columns"),
    )


def lookup_foundation_model_for_event_id(
        inference_id: InferenceEventID,
        history_db: HistoryDB,
) -> FoundationModelRecordOrm | None:
    return history_db.execute(
        select(FoundationModelRecordOrm)
        .join(InferenceEventOrm, InferenceEventOrm.model_record_id == FoundationModelRecordOrm.id)
        .where(InferenceEventOrm.id == inference_id)
    ).scalar_one_or_none()


def inject_inference_stats(
        inference_model: FoundationModelRecord,
        label_to_inject: ProviderLabel,
        history_db: HistoryDB,
        lookback: float | None = 90 * 24 * 60 * 60,
) -> FoundationModelResponse:
    where_clauses = [
        InferenceEventOrm.model_record_id == inference_model.id,
        or_(
            InferenceEventOrm.response_error.is_(None),
            InferenceEventOrm.response_error.is_("null")
        ),
    ]
    if lookback is not None:
        cutoff_time = datetime.now(tz=timezone.utc) - timedelta(seconds=lookback)
        where_clauses.append(InferenceEventOrm.response_created_at > cutoff_time)

    # First, check if there's any stats at all
    has_stats = history_db.execute(
        select(func.count(InferenceEventOrm.id))
        .where(*where_clauses)
    ).scalar_one_or_none()
    if has_stats is None:
        logger.error(f"Received invalid inference stats for {inference_model.human_id}")
        raise NotImplementedError(f"Received invalid inference stats for {inference_model.human_id}")

    # Otherwise, start summarizing stats
    injected_model = FoundationModelResponse(
        **inference_model.model_dump(),
        label=label_to_inject,
    )

    query = (
        select(
            func.count(InferenceEventOrm.id),
            func.sum(InferenceEventOrm.prompt_tokens),
            func.sum(InferenceEventOrm.prompt_eval_time),
            func.sum(InferenceEventOrm.response_tokens),
            func.sum(InferenceEventOrm.response_eval_time),
            func.max(InferenceEventOrm.response_created_at),
        )
        .where(*where_clauses)
    )
    query_result = history_db.execute(query).one_or_none()
    if query_result is None:
        return injected_model

    injected_model.latest_inference_event = query_result[5]
    display_stats = {}
    all_stats = {}

    display_stats["recent inference events"] = query_result[0]
    injected_model.recent_inference_events = query_result[0]

    if query_result[1] is not None:
        all_stats["prompt tokens evaluated"] = query_result[1]
    if query_result[2] is not None:
        all_stats["prompt evaluation time"] = query_result[2]
    if query_result[1] and query_result[2]:
        all_stats["prompt sec/token"] = query_result[2] / query_result[1]
        all_stats["prompt token/sec"] = query_result[1] / query_result[2]

    if query_result[3] is not None:
        all_stats["response tokens returned"] = query_result[3]
        display_stats["response tokens returned"] = query_result[3]
    if query_result[4] is not None:
        all_stats["response inference time"] = query_result[4]
    if query_result[3] and query_result[4]:
        all_stats["response sec/token"] = query_result[4] / query_result[3]
        all_stats["response token/sec"] = query_result[3] / query_result[4]
        display_stats["response token/sec"] = query_result[3] / query_result[4]
        injected_model.recent_tokens_per_second = query_result[3] / query_result[4]

    injected_model.stats = display_stats
    injected_model.all_stats = all_stats

    return injected_model
