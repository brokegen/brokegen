from datetime import datetime
from typing import Optional, TypeAlias

import orjson
from pydantic import BaseModel, ConfigDict, create_model
from sqlalchemy import Column, String, DateTime, JSON, UniqueConstraint

from providers.inference_models.database import Base

ProviderType: TypeAlias = str
ProviderID: TypeAlias = str


class ProviderLabel(BaseModel):
    type: ProviderType
    id: ProviderID

    model_config = ConfigDict(
        extra='forbid',
        frozen=True,
    )


class ProviderRecord(BaseModel):
    identifiers: str
    created_at: Optional[datetime] = None

    machine_info: Optional[dict] = None
    human_info: Optional[str] = None

    model_config = ConfigDict(
        extra='forbid',
        from_attributes=True,
        frozen=True,
    )

    def __hash__(self) -> int:
        return hash((
            self.identifiers,
            self.created_at,
            # NB This is odd, and requires the class to be immutable
            orjson.dumps(self.machine_info),
            self.human_info,
        ))


ProviderAddRequest = create_model(
    'ProviderAddRequest',
    __base__=ProviderRecord,
)

# TODO: This doesn't work, either
ProviderAddRequest.__fields__['identifiers'].annotation = dict


class ProviderRecordOrm(Base):
    """
    For most client code, the Provider is invisible (part of the ModelConfig).

    This is provided separately so we can provide ModelConfigs that work across providers;
    in the simplest case this is just sharing the model name.
    (The advanced case is just sharing all the parameters, and maybe a checksum of the model data.)
    """
    __tablename__ = 'ProviderRecords'

    identifiers = Column(String, primary_key=True, nullable=False)
    "This is generally just JSON; it's kept as a String so it can be used as a primary key"
    created_at = Column(DateTime, primary_key=True, nullable=False)

    machine_info = Column(JSON)
    human_info = Column(String)

    __table_args__ = (
        UniqueConstraint("identifiers", "machine_info", name="all columns"),
    )
