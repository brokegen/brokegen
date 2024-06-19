from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict

from _util.typing import PromptText, RoleName
from client.database import Base


class Embedding(BaseModel):
    role: RoleName
    content: PromptText
    created_at: Optional[datetime]
    "This is a required field for all future events"

    model_config = ConfigDict(
        extra='forbid',
        from_attributes=True,
        frozen=True,
    )


class EmbeddingSource(BaseModel):
    pass


class DocumentOrm(Base):
    pass
