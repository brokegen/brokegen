import asyncio
import logging
import platform
from typing import TypeAlias

import orjson

from _util.json import safe_get_arrayed

logger = logging.getLogger(__name__)

DataType: TypeAlias = str
InfoCacheKey: TypeAlias = tuple[DataType, bool]

info_cache: dict[InfoCacheKey, dict] = {}
"""
We can't just use `functools.lru_cache` because these functions are all `async`.
"""


async def _fetch_macos_info(
        data_type: str,
        # We typically don't need any of the identifiers; serial number doesn't matter because
        # inference results should be identical for identical hardware.
        include_personal_information: bool = False,
        system_profiler_timeout: float | None = 5.0,
) -> dict | None:
    info_cache_key: InfoCacheKey = (data_type, include_personal_information)
    if info_cache_key in info_cache:
        return info_cache[info_cache_key]

    sp_args = ["/usr/sbin/system_profiler", "-json"]
    if include_personal_information:
        sp_args.extend(["-detailLevel", "full"])
    else:
        sp_args.extend(["-detailLevel", "mini"])

    sp_awaitable = asyncio.create_subprocess_exec(
        *sp_args, data_type,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )

    sp_hw_process = await asyncio.wait_for(sp_awaitable, system_profiler_timeout)
    sp_stdout, _ = await sp_hw_process.communicate()
    if sp_stdout is None:
        logger.warning(f"Failed to run `system_profiler {data_type}`")
        return None

    try:
        result = orjson.loads(sp_stdout)
        info_cache[info_cache_key] = result
        return result

    except ValueError:
        return None


async def local_provider_identifiers() -> dict:
    provider_identifiers_dict = {
        'platform': platform.platform(),
    }

    hardware_dict = await _fetch_macos_info("SPHardwareDataType")
    if hardware_dict is not None:
        provider_identifiers_dict.update(hardware_dict)

    return provider_identifiers_dict


async def local_fetch_machine_info() -> dict:
    combined_dict = {}

    hardware_dict = await _fetch_macos_info("SPHardwareDataType")
    if hardware_dict is not None:
        combined_dict.update(hardware_dict)

    software_dict = await _fetch_macos_info("SPSoftwareDataType")
    if software_dict is not None:
        # Delete this entry, since it's always changing and doesn't uniquely identify anyone
        if safe_get_arrayed(software_dict, 'SPSoftwareDataType', 0, 'uptime') is not None:
            del software_dict["SPSoftwareDataType"][0]["uptime"]

        combined_dict.update(software_dict)

    return combined_dict
