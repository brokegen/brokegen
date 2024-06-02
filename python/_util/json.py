from typing import TypeAlias, Any, AnyStr, Dict, List

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
):
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
        except (IndexError, KeyError):
            return None

    return next_json_ish
