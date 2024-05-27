"""
Plain/shared data types, here for dependencies reasons
"""
from typing import TypeAlias

import pydantic

MessageID: TypeAlias = pydantic.PositiveInt
ChatSequenceID: TypeAlias = pydantic.PositiveInt
