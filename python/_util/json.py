import json
from datetime import datetime
from typing import TypeAlias, Any, AnyStr, Dict, List

import jsondiff
from pydantic import BaseModel

# These types aren't strictly defined because they get weirdly recursive
# (can contain themselves/each other/JSONObject).
JSONObject: TypeAlias = Any

JSONDictKey: TypeAlias = AnyStr
JSONDict: TypeAlias = Dict[JSONDictKey, JSONObject]
JSONArray: TypeAlias = List[JSONObject]


def safe_get(
        parent_json_ish: JSONDict | None,
        *keys: JSONDictKey,
) -> JSONObject | None:
    """
    Returns None if any of the intermediate keys failed to appear.

    Only handles dicts, no lists.
    """
    if not parent_json_ish:
        return None

    next_json_ish = parent_json_ish
    for key in keys:
        if key in next_json_ish:
            next_json_ish = next_json_ish[key]
        else:
            return None

    return next_json_ish


def safe_get_arrayed(
        parent_json_ish: JSONDict | JSONArray | None,
        *keys: JSONDictKey | int,
) -> JSONObject | None:
    if not parent_json_ish:
        return None

    next_json_ish = parent_json_ish
    for key in keys:
        if key in next_json_ish:
            next_json_ish = next_json_ish[key]
            continue

        # Check for array-ish behavior
        try:
            next_json_ish = next_json_ish[key]
            continue
        except (TypeError, IndexError, KeyError):
            return None

    return next_json_ish


class DatetimeEncoder(json.JSONEncoder):
    """
    Convenience class that can be used with `json.dumps` to handle non-basic types.

    Usage:

        print(json.dumps(optimized_program.dump_state(), indent=2, cls=DatetimeEncoder))
    """
    def default(self, obj):
        if isinstance(obj, datetime):
            return obj.isoformat()
        else:
            return json.JSONEncoder.default(self, obj)


class CatchAllEncoder(DatetimeEncoder):
    def default(self, obj):
        if isinstance(obj, BaseModel):
            return obj.model_dump()
        elif isinstance(obj, jsondiff.Symbol):
            return str(obj)
        else:
            return DatetimeEncoder.default(self, obj)
