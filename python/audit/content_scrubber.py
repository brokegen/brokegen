from typing import Callable, Any

import orjson

from _util.json import safe_get


def _summarize(images_array: list[str]) -> str:
    image_sizes = map(len, images_array)
    return f"{len(images_array)} images scrubbed, image base64-encoded sizes: {list(image_sizes)}"


async def scrub_json(
        content_json,
        logger_fn: Callable[[str], Any] | None = None,
        remove_images: bool = False,
):
    if remove_images:
        for message in safe_get(content_json, "messages"):
            if "images" in message and message["images"]:
                message["images"] = _summarize(message["images"])

    return content_json


async def scrub_bytes(
        content_bytes: bytes,
        logger_fn: Callable[[str], Any] | None = None,
        remove_images: bool = False,
) -> bytes | None:
    if not content_bytes:
        return None

    if logger_fn is None:
        logger_fn = lambda s: ()

    try:
        content_json = orjson.loads(content_bytes)
        scrubbed_json = await scrub_json(content_json, logger_fn, remove_images)
        return orjson.dumps(scrubbed_json)

    except orjson.JSONDecodeError:
        logger_fn(f"Failed to decode HTTP Request JSON, any images will remain ({len(content_bytes)=})")
        return None
