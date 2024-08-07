"""
Plain/shared data types, here for dependencies reasons
"""
from typing import TypeAlias, Protocol

import pydantic
from pydantic import PositiveInt

PromptText: TypeAlias = str
"Text provided by any agent or RAG, prior to templating"

TemplatedPromptText: TypeAlias = str
"PromptText after template applied, ready to send to /api/generate as raw=True request"

RoleName: TypeAlias = str
"""
Virtually always 'user' or 'assistant', occasionally 'system'.

Using a non-standard role makes it easier to bypass model censoring, since chat-focused
LLMs are usually trained with ChatML surrounding the 'assistant' token.
"""

ChatMessageID: TypeAlias = pydantic.PositiveInt
ChatSequenceID: TypeAlias = pydantic.PositiveInt

FoundationModelRecordID: TypeAlias = PositiveInt
FoundationModelHumanID: TypeAlias = str

InferenceReason: TypeAlias = str
"""TODO: Should be an enum, but enums for SQLAlchemy take some work"""


class GenerateHelper(Protocol):
    """
    Type hint for function that provides LLM inference.

    - auto-summary of RAG-retrieval documents, to compress into a given context window
    - autonaming of ChatSequences
    """
    async def __call__(
            self,
            inference_reason: InferenceReason,
            system_message: PromptText | None,
            user_prompt: PromptText,
            assistant_response: PromptText | None,
    ) -> PromptText: ...

