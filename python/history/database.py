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


class ModelConfigRecord(Base):
    __tablename__ = 'ModelConfigRecords'

    id = Column(Integer, primary_key=True, autoincrement=True)

    machine_id = Column(String, nullable=False)
    human_id = Column(String, nullable=False)
    first_seen_at = Column(DateTime)

    inference_params = Column(JSON)
