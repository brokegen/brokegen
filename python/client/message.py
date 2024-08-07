from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict
from sqlalchemy import Column, String, DateTime, Integer, select

from _util.json import JSONDict
from _util.typing import ChatMessageID, PromptText, RoleName, ChatSequenceID
from .database import Base, HistoryDB


class ChatMessage(BaseModel):
    role: RoleName
    content: PromptText
    created_at: Optional[datetime] = None
    "This is a required field for all future events"

    model_config = ConfigDict(
        extra='forbid',
        from_attributes=True,
        frozen=True,
    )


class ChatMessageResponse(ChatMessage):
    message_id: ChatMessageID
    sequence_id: ChatSequenceID


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
        return f"ChatMessage#{self.id}"

    def __repr__(self) -> str:
        return f"<ChatMessage#{self.id} role={self.role} content={self.content}>"


def lookup_chat_message(
        message_in: ChatMessage,
        history_db: HistoryDB,
) -> ChatMessageOrm | None:
    where_clauses = [
        ChatMessageOrm.role == message_in.role,
        ChatMessageOrm.content == message_in.content,
    ]

    return history_db.execute(
        select(ChatMessageOrm)
        .where(*where_clauses)
        .limit(1)
        .order_by(ChatMessageOrm.created_at.desc())
    ).scalar_one_or_none()
