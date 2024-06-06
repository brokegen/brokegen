from datetime import datetime
from typing import Optional, Iterator

from pydantic import BaseModel, ConfigDict
from sqlalchemy import Column, String, DateTime, Integer, Boolean, select

from _util.json import JSONDict
from _util.typing import ChatMessageID, ChatSequenceID, PromptText, RoleName
from providers.inference_models.database import Base, HistoryDB


class ChatMessage(BaseModel):
    role: RoleName
    content: PromptText
    created_at: Optional[datetime]
    "This is a required field for all future events"

    model_config = ConfigDict(
        extra='forbid',
        from_attributes=True,
        frozen=True,
    )


class ChatMessageOrm(Base):
    __tablename__ = 'ChatMessages'

    id: ChatMessageID = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    role: RoleName = Column(String, nullable=False)
    content: PromptText = Column(String, nullable=False)

    created_at = Column(DateTime)
    """
    This is really a vanity field, for the sake of making browsing raw SQLite data less boring.

    The rest of the data structures are… too brittle and unstructured, though.
    """

    def as_json(self) -> JSONDict:
        cols = ChatMessageOrm.__mapper__.columns
        return dict([
            (col.name, getattr(self, col.name)) for col in cols
        ])

    def __str__(self) -> str:
        return f"<ChatMessage#{self.id} role={self.role} content={self.content}>"


def lookup_chat_message(
        message_in: ChatMessage,
        history_db: HistoryDB,
) -> ChatMessageOrm | None:
    where_clauses = [
        ChatMessageOrm.role == message_in.role,
        ChatMessageOrm.content == message_in.content,
    ]
    if message_in.created_at is not None:
        where_clauses.append(ChatMessageOrm.created_at == message_in.created_at)

    return history_db.execute(
        select(ChatMessageOrm)
        .where(*where_clauses)
        .limit(1)
        .order_by(ChatMessageOrm.created_at.desc())
    ).scalar_one_or_none()


class ChatSequence(Base):
    """
    Represents a linked list node for Message sequences.
    """
    __tablename__ = 'ChatSequences'

    id: ChatSequenceID = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    human_desc = Column(String)
    user_pinned = Column(Boolean)
    """
    Marks the messages we want to show in the main view.
    Double duty as top-of-thread and also regular-branching-point.
    """

    current_message: ChatMessageID = Column(Integer, nullable=False)
    parent_sequence: ChatSequenceID = Column(Integer)

    generated_at = Column(DateTime)
    generation_complete = Column(Boolean)
    inference_job_id = Column(Integer)  # InferenceEventOrm.id
    inference_error = Column(String)

    def __str__(self) -> str:
        return f"<ChatSequence#{self.id} current_message={self.current_message} parent_sequence={self.parent_sequence}>"


def lookup_sequence_parents(
        current_id: ChatSequenceID | None,
        history_db: HistoryDB,
) -> Iterator[ChatSequence]:
    # TODO: We should take advantage of the ORM relationship, rather than doing this
    while current_id is not None:
        sequence = history_db.execute(
            select(ChatSequence)
            .where(ChatSequence.id == current_id)
        ).scalar_one()

        yield sequence
        current_id = sequence.parent_sequence


class VisibleSequence:
    """
    Represents a more user-visible concept of message chains.

    In particular, having the summary of prior messages + possible token estimates.
    """
    __tablename__ = 'ChatSequences'

    id = Column(Integer, primary_key=True, nullable=False)
    top_node: ChatSequenceID
