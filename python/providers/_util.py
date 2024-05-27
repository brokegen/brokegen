import asyncio
import functools
import logging
import platform
import uuid

import orjson

from _util.json import safe_get_arrayed

logger = logging.getLogger(__name__)


@functools.lru_cache(maxsize=1)
def local_provider_identifiers() -> dict:
    provider_identifiers_dict = {
        'platform': platform.platform(),
        # https://docs.python.org/3/library/uuid.html#uuid.getnode
        # This is based on the MAC address of a network interface on the host system; the important
        # thing is that the ProviderConfigRecord differs when the setup might give different results.
        'node_id': uuid.getnode(),
    }
    return provider_identifiers_dict


async def local_fetch_machine_info(
        include_personal_information: bool = True,
        system_profiler_timeout: float | None = 5.0,
):
    sp_args = ["/usr/sbin/system_profiler", "-json"]
    if include_personal_information:
        sp_args.extend(["-detailLevel", "mini"])

    combined_dict = {}

    sp_hw_awaitable = asyncio.create_subprocess_exec(
        *sp_args, "SPHardwareDataType",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )

    sp_hw_process = await asyncio.wait_for(sp_hw_awaitable, system_profiler_timeout)
    stdout_hw, _ = await sp_hw_process.communicate()
    if stdout_hw is None:
        logger.info("Failed to run system_profiler SPHardwareDataType, continuing without")
    else:
        hardware_dict = orjson.loads(stdout_hw)
        combined_dict.update(hardware_dict)

    sp_sw_awaitable = asyncio.create_subprocess_exec(
        *sp_args, "SPSoftwareDataType",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )

    sp_sw_process = await asyncio.wait_for(sp_sw_awaitable, system_profiler_timeout)
    stdout_sw, _ = await sp_sw_process.communicate()
    if stdout_sw is None:
        logger.info("Failed to run system_profiler SPSoftwareDataType, continuing without")
    else:
        software_dict = orjson.loads(stdout_sw)
        if safe_get_arrayed(software_dict, 'SPSoftwareDataType', 0, 'uptime'):
            # Delete this entry, since it's always changing and doesn't uniquely identify anyone
            del software_dict["SPSoftwareDataType"][0]["uptime"]

        combined_dict.update(software_dict)

    return combined_dict
