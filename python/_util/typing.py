"""
Plain/shared data types, here for dependencies reasons
"""
from typing import TypeAlias

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

InferenceModelRecordID: TypeAlias = PositiveInt
InferenceModelHumanID: TypeAlias = str
