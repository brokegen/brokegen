from collections.abc import Callable, Generator
from typing import TypeAlias

from sqlalchemy import create_engine, Column, String, DateTime, JSON, Integer
from sqlalchemy.orm import declarative_base, sessionmaker, Session

engine = None
SessionLocal: Callable = None
Base = declarative_base()

AuditDB: TypeAlias = Session


def init_db(db_path: str) -> None:
    global engine
    engine = create_engine(
        'sqlite:///' + db_path,
        connect_args={
            "check_same_thread": False,
            "timeout": 1,
        })

    Base.metadata.create_all(bind=engine)

    global SessionLocal
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_db() -> Generator[AuditDB]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


class EgressHttpEvent(Base):
    """
    Reduced version of RawHttpEvent, intended to be human-readable
    """
    __tablename__ = 'EgressHttpEvents'
    __bind_key__ = 'access'

    id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    api_bucket = Column(String)
    accessed_at = Column(DateTime, nullable=False)

    request_info = Column(JSON)
    "Freeform field that includes whatever the logger thinks is appropriate"
    response_content = Column(JSON)
    response_info = Column(JSON)
    "Freeform field, generally only used if response_content couldn't be parsed correctly"
