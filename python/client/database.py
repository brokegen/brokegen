from collections.abc import Generator
from typing import TypeAlias

from sqlalchemy import create_engine, NullPool, StaticPool
from sqlalchemy.orm import declarative_base, sessionmaker, Session

SessionLocal: sessionmaker | None = None
Base = declarative_base()

HistoryDB: TypeAlias = Session


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


def load_db_models_pytest():
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
