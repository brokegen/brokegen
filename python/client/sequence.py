from datetime import datetime
from typing import Iterator, Optional, Union

from pydantic import BaseModel, ConfigDict, PositiveInt
from sqlalchemy import Column, Integer, String, Boolean, DateTime, select

from _util.typing import ChatSequenceID, ChatMessageID, FoundationModelRecordID, RoleName, PromptText
from .message import ChatMessage, ChatMessageResponse
from .database import Base, HistoryDB


class ChatSequence(BaseModel):
    id: ChatSequenceID
    human_desc: Optional[str] = None
    user_pinned: bool

    current_message: ChatMessageID
    parent_sequence: Optional[ChatSequenceID]

    generated_at: datetime
    generation_complete: bool
    inference_job_id: Optional[PositiveInt] = None
    """Should be `providers.foundation_models.orm.InferenceEventID`, but circular import, for now."""
    inference_error: Optional[str] = None

    model_config = ConfigDict(
        from_attributes=True,
    )


class InfoMessageOut(BaseModel):
    """
    This class is a bridge between "real" user/assistant messages,
    and ModelConfigRecord changes.

    TODO: Once we've written client support to render config changes,
          remove this and replace with a real config change.
    """
    role: RoleName = 'model info'
    content: PromptText


class ChatSequenceResponse(ChatSequence):
    messages: list[Union[ChatMessage, ChatMessageResponse, InfoMessageOut]]
    inference_model_id: Optional[FoundationModelRecordID] = None

    is_leaf_sequence: Optional[bool]
    parent_sequences: list[ChatSequenceID]


class ChatSequenceOrm(Base):
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
        return f"<ChatSequence#{self.id}>"

    def __repr__(self) -> str:
        return f"<ChatSequence#{self.id} current_message={self.current_message} parent_sequence={self.parent_sequence}>"


def lookup_sequence_parents(
        current_id: ChatSequenceID | None,
        history_db: HistoryDB,
) -> Iterator[ChatSequenceOrm]:
    # TODO: We should take advantage of the ORM relationship, rather than doing this
    while current_id is not None:
        sequence = history_db.execute(
            select(ChatSequenceOrm)
            .where(ChatSequenceOrm.id == current_id)
        ).scalar_one()

        yield sequence
        current_id = sequence.parent_sequence
