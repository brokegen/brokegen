from datetime import datetime

from _util.typing import PromptText, ChatMessageID
from client.database import HistoryDB
from client.message import ChatMessageOrm
from client.sequence import ChatSequenceOrm
from providers.foundation_models.orm import InferenceEventOrm


def construct_assistant_message(
        maybe_response_seed: PromptText,
        assistant_response: PromptText,
        created_at: datetime,
        history_db: HistoryDB,
) -> ChatMessageOrm | None:
    assistant_message_to_append: PromptText = maybe_response_seed + assistant_response
    if not assistant_message_to_append:
        return None

    assistant_message = ChatMessageOrm(
        role="assistant",
        content=assistant_message_to_append,
        created_at=created_at,
    )

    history_db.add(assistant_message)
    history_db.commit()

    return assistant_message


async def construct_new_sequence_from(
        original_sequence: ChatSequenceOrm,
        assistant_message_to_append: ChatMessageID,
        inference_event: InferenceEventOrm,
        history_db: HistoryDB,
) -> ChatSequenceOrm:
    """
    Generic post-inference sequence recorder.

    - expects `inference_event` to already be populated, just missing our SequenceID
    """
    # Add what we need for response_sequence
    response_sequence = ChatSequenceOrm(
        human_desc=original_sequence.human_desc,
        user_pinned=False,
        current_message=assistant_message_to_append,
        parent_sequence=original_sequence.id,
    )

    history_db.add(response_sequence)

    response_sequence.generated_at = inference_event.response_created_at
    response_sequence.generation_complete = True
    response_sequence.inference_job_id = inference_event.id
    if inference_event.response_error:
        response_sequence.inference_error = inference_event.response_error

    history_db.commit()

    # And complete the circular reference that really should be handled in the SQLAlchemy ORM
    inference_job = history_db.merge(inference_event)
    inference_job.parent_sequence = response_sequence.id

    history_db.add(inference_job)
    history_db.commit()

    return response_sequence
