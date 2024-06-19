from typing import Iterator

from sqlalchemy import Column, Integer, String, Boolean, DateTime, select

from _util.typing import ChatSequenceID, ChatMessageID
from client.database import Base, HistoryDB


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
        return f"<ChatSequence#{self.id}>"

    def __repr__(self) -> str:
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
