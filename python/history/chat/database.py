from typing import TypeAlias

from sqlalchemy import Column, String, DateTime, Integer, Boolean

from history.shared.database import Base
from prompting.models import RoleName, PromptText

MessageID: TypeAlias = int
ChatSequenceID: TypeAlias = int


class Message(Base):
    __tablename__ = 'Messages'

    id: MessageID = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    role: RoleName = Column(String, nullable=False)
    content: PromptText = Column(String, nullable=False)


class ChatSequence(Base):
    __tablename__ = 'ChatSequence'

    id: ChatSequenceID = Column(String, primary_key=True, nullable=False)

    current_message: MessageID = Column(Integer)
    parent_sequence: ChatSequenceID = Column(Integer)

    generated_at = Column(DateTime)
    generation_complete = Column(Boolean)
    inference_job_id = Column(Integer)
    inference_error = Column(String)
