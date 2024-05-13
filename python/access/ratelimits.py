"""
For potential debugging and caching purposes, offer infrastructure for every network request we make.

Ideally, we would use something like `structlog` or `logging.handlers.HTTPHandler` to send logs elsewhere,
but this will work for the small scale we have (one user, no automation of LLM requests).
"""
from collections.abc import Callable
from typing import TypeAlias

from sqlalchemy import create_engine, Column, String, DateTime, JSON, Integer
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session

engine = None
SessionLocal: Callable = None
Base = declarative_base()

RatelimitsDB: TypeAlias = Session


def init_db(db_path: str) -> None:
    global engine
    engine = create_engine(
        'sqlite:///' + db_path,
        connect_args={
            "check_same_thread": False,
            "timeout"          : 1,
        })

    Base.metadata.create_all(bind=engine)

    global SessionLocal
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_db() -> RatelimitsDB:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


class ApiAccess(Base):
    __tablename__ = 'ApiAccesses'
    __bind_key__ = 'ratelimits'

    accessed_at = Column(DateTime, primary_key=True, nullable=False)
    api_endpoint = Column(String, primary_key=True, nullable=False)

    api_bucket = Column(String, primary_key=True, nullable=False)
    response_status_code = Column(Integer)

    def __str__(self):
        maybe_api_bucket = ""
        if self.api_bucket:
            maybe_api_bucket = f" \"{self.api_bucket}\""

        return f"<ApiAccesses{maybe_api_bucket} @ {self.accessed_at}>"


class ApiAccessWithResponse(Base):
    __tablename__ = 'ApiAccessesWithResponse'
    __bind_key__ = 'ratelimits'

    accessed_at = Column(DateTime, primary_key=True, nullable=False)
    api_endpoint = Column(String, primary_key=True, nullable=False)

    api_bucket = Column(String, primary_key=True, nullable=False)
    request = Column(JSON)
    response = Column(JSON)
