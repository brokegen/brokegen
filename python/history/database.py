"""
For now, we are simply intercepting and recording Ollama-like requests.

Specifically, let's just record Ollama model info.
"""
try:
    import orjson as json
except ImportError:
    import json

from collections.abc import Callable, Generator
from typing import TypeAlias

from sqlalchemy import create_engine, Column, String, DateTime, JSON, Integer
from sqlalchemy.orm import declarative_base, sessionmaker, Session

SessionLocal: Callable = None
Base = declarative_base()

HistoryDB: TypeAlias = Session


def init_db(db_path: str) -> None:
    engine = create_engine(
        'sqlite:///' + db_path,
        connect_args={
            "check_same_thread": False,
            "timeout": 1,
        })

    Base.metadata.create_all(bind=engine)

    global SessionLocal
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_db() -> Generator[HistoryDB]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


class ExecutorConfigRecord(Base):
    __tablename__ = 'ExecutorConfigRecords'

    id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)

    # This should be the primary key, but the ORM layer would need us to encode it as str
    executor_info = Column(JSON, nullable=False, unique=True)
    created_at = Column(DateTime)


class ModelConfigRecord(Base):
    __tablename__ = 'ModelConfigRecords'

    id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)

    human_id = Column(String, nullable=False)
    first_seen_at = Column(DateTime)
    last_seen = Column(DateTime)

    executor_info = Column(JSON, nullable=False)  # relationship=ExecutorConfigRecord.executor_info)
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


class InferenceJob(Base):
    __tablename__ = 'InferenceJobs'

    id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    raw_prompt = Column(String)
    "Can be NULL; in which case, we have enough in model_config to reconstruct it"

    model_config = Column(Integer, nullable=False)  # ModelConfigRecord.id
    overridden_inference_params = Column(JSON)
    response_stats = Column(JSON)


class Message(Base):
    __tablename__ = 'Messages'

    id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)

    role = Column(String, nullable=False)
    prompt = Column(String, nullable=False)

    inference_job = Column(Integer, nullable=False)
