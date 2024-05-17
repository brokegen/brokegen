import asyncio
import logging
import os

import filelock

from inference.embeddings.knowledge import KnowledgeSingleton

logger = logging.getLogger(__name__)


class MockLoader:
    def __init__(self, logger: logging.Logger):
        self.logger = logger

    async def supports_filename(self, full_filepath):
        return True

    async def index_one_file(self, full_filepath, allow_progress_bars):
        return f"{os.path.basename(full_filepath)} not supported"


async def bulk_loader(
        filenames_generator,
        knowledge: KnowledgeSingleton,
):
    big_loader = MockLoader(logger)

    # DEBUG: Drop this down to "1", so we don't overwhelm Ollama with requests.
    #
    # TODO: Switch over to using env variables, or Depends, or pydantic-settings, to decide whether to multi-thread,
    #       and whether to show progress bars.
    sem = asyncio.Semaphore(1)

    async def do_indexing(task_id, full_filepath, max_retries: int = 3) -> str:
        if not await big_loader.supports_filename(full_filepath):
            return f"{task_id}: {full_filepath} not supported"

        while max_retries > 0:
            max_retries -= 1

            try:
                async with sem:
                    logger.debug(f"Reading #{task_id} {full_filepath=}")

                    result = await big_loader.index_one_file(
                        full_filepath,
                        allow_progress_bars=True,
                    )

                logger.debug(f"Done with {task_id}: {result}")
                return f"{task_id}: {result}"

            except filelock.Timeout as e:
                logger.error(f"Failed {task_id}: {e}")
                return f"{task_id}: {e}"

            except ValueError as e:
                # Treat this as an inference error, always
                # TODO: The retries don't really seem to be working.
                logger.error(f"Failed {task_id}, {max_retries} retries left: {e}")
                if max_retries > 0:
                    continue
                else:
                    return f"{task_id}: {e}"

            except Exception as e:
                logger.exception(f"Failed {task_id}")
                return f"{task_id}: {e}"

    return await asyncio.gather(
        *[do_indexing(task_id, full_filepath) for task_id, full_filepath in filenames_generator]
    )
