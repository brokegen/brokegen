from typing import Iterable, AsyncIterable, TypeAlias, Any, AnyStr, Dict, List

import starlette.datastructures
from starlette.background import BackgroundTask
from starlette.concurrency import iterate_in_threadpool
from starlette.responses import StreamingResponse, JSONResponse

# These types aren't strictly defined because they get weirdly recursive
# (can contain themselves/each other/JSONObject).
JSONObject: TypeAlias = Any

JSONDictKey: TypeAlias = AnyStr
JSONDict: TypeAlias = Dict[JSONDictKey, JSONObject]
JSONArray: TypeAlias = List[JSONObject]


def safe_get(
        parent_json_ish: JSONDict | JSONArray | None,
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


class JSONStreamingResponse(StreamingResponse, JSONResponse):
    def __init__(
            self,
            content: Iterable | AsyncIterable,
            status_code: int = 200,
            headers: starlette.datastructures.MutableHeaders | dict[str, str] | None = None,
            media_type: str | None = None,
            background: BackgroundTask | None = None,
    ) -> None:
        if isinstance(content, AsyncIterable):
            self._content_iterable: AsyncIterable = content
        else:
            self._content_iterable = iterate_in_threadpool(content)

        async def body_iterator() -> AsyncIterable[bytes]:
            async for content_ in self._content_iterable:
                if isinstance(content_, bytes):
                    yield content_
                else:
                    yield self.render(content_)

        self.body_iterator = body_iterator()
        self.status_code = status_code
        if media_type is not None:
            self.media_type = media_type
        self.background = background
        self.init_headers(headers)
