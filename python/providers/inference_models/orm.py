from datetime import datetime
from typing import TypeAlias, Optional, Self

from pydantic import PositiveInt, BaseModel, ConfigDict, create_model
from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, JSON, Double, select

from inference.prompting.models import TemplatedPromptText
from providers.inference_models.database import Base, HistoryDB
from providers.orm import ProviderRecord, ProviderLabel

InferenceModelRecordID: TypeAlias = PositiveInt
InferenceModelHumanID: TypeAlias = str

InferenceEventID: TypeAlias = PositiveInt


class InferenceModelLabel(BaseModel):
    provider: ProviderLabel
    human_id: InferenceModelHumanID

    model_config = ConfigDict(
        extra='forbid',
        frozen=True,
    )


class InferenceModelRecord(BaseModel):
    id: Optional[InferenceModelRecordID] = None
    human_id: InferenceModelHumanID

    first_seen_at: Optional[datetime] = None
    last_seen: Optional[datetime] = None

    provider_identifiers: str
    model_identifiers: Optional[dict] = str

    combined_inference_parameters: Optional[dict] = str

    model_config = ConfigDict(
        extra='forbid',
        from_attributes=True,
        frozen=True,
    )


InferenceModelAddRequest = create_model(
    'InferenceModelAddRequest',
    __base__=InferenceModelRecord,
)

# TODO: Neither of these truly work
InferenceModelAddRequest.__fields__['provider_identifiers'].exclude = True
del InferenceModelAddRequest.__fields__['provider_identifiers']


class InferenceModelRecordOrm(Base):
    __tablename__ = 'InferenceModelRecords'

    id: InferenceModelRecordID = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    human_id: InferenceModelHumanID = Column(String, nullable=False)

    first_seen_at = Column(DateTime)
    last_seen = Column(DateTime)

    provider_identifiers: str = Column(String, ForeignKey('ProviderRecords.identifiers'), nullable=False)
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

    def merge_in_updates(self, model_in: InferenceModelRecord) -> Self:
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

        if not self.model_identifiers:
            self.model_identifiers = model_in.model_identifiers

        if not self.combined_inference_parameters:
            self.combined_inference_parameters = model_in.combined_inference_parameters

        return self

    def as_json(self):
        cols = InferenceModelRecordOrm.__mapper__.columns
        return dict([
            (col.name, getattr(self, col.name)) for col in cols
        ])


def lookup_inference_model_record(
        provider_record: ProviderRecord,
        human_id: InferenceModelHumanID,
        history_db: HistoryDB,
) -> InferenceModelRecordOrm | None:
    return history_db.execute(
        select(InferenceModelRecordOrm)
        .where(InferenceModelRecordOrm.provider_identifiers == provider_record.identifiers,
               InferenceModelRecordOrm.human_id == human_id)
        .order_by(InferenceModelRecordOrm.last_seen.desc())
        .limit(1)
    ).scalar_one_or_none()


def lookup_inference_model_record_detailed(
        model_in: InferenceModelAddRequest,
        history_db: HistoryDB,
) -> InferenceModelRecordOrm | None:
    return history_db.execute(
        select(InferenceModelRecordOrm)
        .filter_by(
            human_id=model_in.human_id,
            provider_identifiers=model_in.provider_identifiers,
            model_identifiers=model_in.model_identifiers,
            combined_inference_parameters=model_in.combined_inference_parameters,
        )
        .order_by(InferenceModelRecordOrm.last_seen.desc())
        .limit(1)
    ).scalar_one_or_none()


class InferenceEventOrm(Base):
    """
    These are basically 1:1 with ChatSequences, though sub-queries will also generate these.

    Primary purpose of these records is estimating tokens/second, or extrapolating time/money costs
    for having a different executor do the inference.
    """
    __tablename__ = 'InferenceEvents'

    id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    model_config: InferenceModelRecordID = Column(Integer, nullable=False)

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
