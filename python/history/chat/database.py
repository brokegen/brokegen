from sqlalchemy import Column, String, DateTime, Integer, Boolean

from _util.json import JSONDict
from _util.typing import MessageID, ChatSequenceID
from inference.prompting.models import RoleName, PromptText
from providers.inference_models.database import Base


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

    def as_json(self) -> JSONDict:
        cols = Message.__mapper__.columns
        return dict([
            (col.name, getattr(self, col.name)) for col in cols
        ])

    def __str__(self) -> str:
        return f"<ChatMessage#{self.id} role={self.role} content={self.content}>"


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


class VisibleSequence:
    """
    Represents a more user-visible concept of message chains.

    In particular, having the summary of prior messages + possible token estimates.
    """
    __tablename__ = 'ChatSequences'

    id = Column(Integer, primary_key=True, nullable=False)
    top_node: ChatSequenceID
