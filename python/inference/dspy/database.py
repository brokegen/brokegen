import logging
from collections.abc import Generator
from typing import TypeAlias

from sqlalchemy import Column, Integer, String, JSON
from sqlalchemy import create_engine, NullPool
from sqlalchemy.orm import declarative_base, sessionmaker, Session

from _util.typing import FoundationModelRecordID

logger = logging.getLogger(__name__)

SessionLocal: sessionmaker | None = None
Base = declarative_base()

PromptDB: TypeAlias = Session


class TrainingExample(Base):
    __tablename__ = 'TrainingExamples'
    id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)

    category = Column(String, nullable=False)
    """
    Type of training this example can be used for.
    We could possibly download external training sets to this table, and use this field to identify that dataset.
    """
    example = Column(JSON, nullable=False)
    """
    Very generic field that's passed basically as-is to DSPy, which needs minimal labeling.
    """


class StoredProgram(Base):
    __tablename__ = 'StoredPrograms'
    id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)

    model_record_id: FoundationModelRecordID = Column(Integer, nullable=False)
    """
    Should technically be a foreign key, but there's not _really_ a lot of need to link across databases.
    """
    program_dump = Column(JSON, nullable=False)


def load_db_models(db_path: str) -> None:
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


def get_prompt_db() -> Generator[PromptDB]:
    db: PromptDB = SessionLocal()
    try:
        yield db
    finally:
        db.close()
