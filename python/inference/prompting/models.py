from typing import TypeAlias

from pydantic import BaseModel

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


class ChatMessage(BaseModel):
    pass

    # TODO: These are actually JSON fields, how would Pydantic work?
    #role: RoleName
    #content: PromptText
