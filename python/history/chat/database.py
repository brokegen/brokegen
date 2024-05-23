from typing import TypeAlias

import pydantic
from sqlalchemy import Column, String, DateTime, Integer, Boolean

from history.shared.database import Base
from inference.prompting.models import RoleName, PromptText

MessageID: TypeAlias = pydantic.PositiveInt
ChatSequenceID: TypeAlias = pydantic.PositiveInt


class Message(Base):
    __tablename__ = 'Messages'

    id: MessageID = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    role: RoleName = Column(String, nullable=False)
    content: PromptText = Column(String, nullable=False)

    created_at = Column(DateTime)
    """
    This is really a vanity field, for the sake of making browsing raw SQLite data less boring.

    The rest of the data structures are… too brittle and unstructured, though.
    """


class ChatSequence(Base):
    """
    Represents a linked list node for Message sequences.
    """
    __tablename__ = 'ChatSequence'

    id: ChatSequenceID = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    human_desc = Column(String)
    user_pinned = Column(Boolean)
    """
    Marks the messages we want to show in the main view.
    Double duty as top-of-thread and also regular-branching-point.
    """

    current_message: MessageID = Column(Integer, nullable=False)
    parent_sequence: ChatSequenceID = Column(Integer)

    generated_at = Column(DateTime)
    generation_complete = Column(Boolean)
    inference_job_id = Column(Integer)
    inference_error = Column(String)
