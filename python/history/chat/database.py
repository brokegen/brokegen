from typing import TypeAlias

from sqlalchemy import Column, String, DateTime, Integer, Boolean

from history.database import Base

MessageID: TypeAlias = int


class Message(Base):
    __tablename__ = 'Messages'

    id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    role = Column(String, nullable=False)
    content = Column(String, nullable=False)


class ChatSequence(Base):
    __tablename__ = 'ChatSequence'

    id = Column(String, primary_key=True, nullable=False)

    current_message = Column(Integer)
    parent_sequence = Column(Integer)

    generated_at = Column(DateTime)
    generation_complete = Column(Boolean)
    inference_job_id = Column(Integer)
    inference_error = Column(String)
