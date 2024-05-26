try:
    import orjson as json
except ImportError:
    import json

from collections.abc import Generator
from typing import TypeAlias

from pydantic import PositiveInt
from sqlalchemy import create_engine, Column, String, DateTime, JSON, Integer, NullPool, StaticPool, Double, ForeignKey
from sqlalchemy.orm import declarative_base, sessionmaker, Session

from inference.prompting.models import TemplatedPromptText

SessionLocal: sessionmaker | None = None
Base = declarative_base()

HistoryDB: TypeAlias = Session

ModelConfigID: TypeAlias = PositiveInt
InferenceJobID: TypeAlias = PositiveInt


def load_models(db_path: str) -> None:
    engine = create_engine(
        'sqlite:///' + db_path,
        connect_args={
            "check_same_thread": False,
            "timeout": 1,
        },
        # NB This breaks pytests.
        poolclass=NullPool,
    )

    Base.metadata.create_all(bind=engine)

    global SessionLocal
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def load_models_pytest():
    engine = create_engine(
        'sqlite:///',
        connect_args={
            "check_same_thread": False,
        },
        # https://stackoverflow.com/questions/74536228/sqlalchemy-doesnt-correctly-create-in-memory-database
        # Must be used, since in-memory database only exists in scope of connection
        poolclass=StaticPool,
        # Can also be done with `logging.getLogger('sqlalchemy.engine').setLevel(logging.INFO)`
        echo=True,
    )
    Base.metadata.create_all(bind=engine)

    global SessionLocal
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_db() -> Generator[HistoryDB]:
    db: HistoryDB = SessionLocal()
    try:
        yield db
    finally:
        db.close()


class ProviderRecordOrm(Base):
    """
    For most client code, the Provider is invisible (part of the ModelConfig).

    This is provided separately so we can provide ModelConfigs that work across providers;
    in the simplest case this is just sharing the model name.
    (The advanced case is just sharing all the parameters, and maybe a checksum of the model data.)
    """
    __tablename__ = 'ProviderRecords'

    provider_identifiers = Column(String, primary_key=True, nullable=False)
    "This is generally encoded JSON; it's kept as a String so it can be used as an identifier"
    created_at = Column(DateTime, primary_key=True, nullable=False)

    machine_info = Column(JSON)
    human_info = Column(String)


class ModelConfigRecord(Base):
    __tablename__ = 'ModelConfigRecords'

    id: ModelConfigID = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    human_id = Column(String, nullable=False)

    first_seen_at = Column(DateTime)
    last_seen = Column(DateTime)

    provider_identifiers = Column(String, ForeignKey('ProviderRecords.provider_identifiers'), nullable=False)
    static_model_info = Column(JSON)
    """
    Contains parameters that are not something our client can change,
    e.g. if user updated/created a new ollama model that reuses the same `human_id`.

    This can be surfaced to the end user, but since it's virtually inactionable,
    should be shown differently.
    """

    default_inference_params = Column(JSON)
    """
    Parameters that can be overridden at "runtime", i.e. by individual message calls.
    If these change, they are likely to be intentional and temporary changes, e.g.:

    - intentional: the client overrides the system prompt
    - intentional: the set of stop tokens changes for a different prompt type
    - temporary: the temperature used for inference is being prompt-engineered by DSPy

    These will be important to surface to the user, but that's _because_ they were
    assumed to be changed in response to user actions.
    """

    def as_json(self):
        cols = ModelConfigRecord.__mapper__.columns
        return dict([
            (col.name, getattr(self, col.name)) for col in cols
        ])


class InferenceEvent(Base):
    """
    These are basically 1:1 with ChatSequences, though sub-queries will also generate these.

    Primary purpose of these records is estimating tokens/second, or extrapolating time/money costs
    for having a different executor do the inference.
    """
    __tablename__ = 'InferenceJobs'

    id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    model_config: ModelConfigID = Column(Integer, nullable=False)

    prompt_tokens = Column(Integer)
    prompt_eval_time = Column(Double)
    "Total time in seconds (Apple documentation for timeIntervalSince uses seconds, so why not)"
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
