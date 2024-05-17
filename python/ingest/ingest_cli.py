"""
Offline, standalone CLI that converts files into LLM input.

- sorts through files in a given directory
- paging implemented with skip/offset indices, valid if the directory contents don't change (alphabetically sorted)
- filtering implemented with file suffixes

Output:

- content is SemanticChunker'd and put into data/knowledge.db
- chunked content is passed through the OllamaEmbedder and then written to its matching .faiss/.pkl

The updated contents can then be used by the main FastAPI endpoint to serve embeddings.
"""

# https://pyinstaller.org/en/v6.6.0/common-issues-and-pitfalls.html#common-issues
if __name__ == '__main__':
    import multiprocessing
    multiprocessing.freeze_support()

import asyncio
import logging
import os
import sys
from contextlib import asynccontextmanager
from pprint import pprint
from typing import Iterable

import click
import pypandoc

import ingest.filesystem
from inference.embeddings.knowledge import get_knowledge

logger = logging.getLogger(__name__)


def reconfigure_loglevels():
    root_logger = logging.getLogger()

    try:
        import colorlog
        from colorlog import ColoredFormatter

        LOGFORMAT = "  %(log_color)s%(levelname)-8s%(reset)s | %(log_color)s%(message)s%(reset)s"
        formatter = ColoredFormatter(LOGFORMAT)

        colorlog_stdout = logging.StreamHandler()
        colorlog_stdout.setLevel(logging.DEBUG)
        colorlog_stdout.setFormatter(formatter)
        root_logger.handlers = [colorlog_stdout]

        # https://github.com/tiangolo/fastapi/discussions/7457
        # Convert uvicorn logging to this format also
        logging.getLogger("uvicorn.access").handlers = [colorlog_stdout]

    except ImportError:
        logging.basicConfig()


# Early call, because I can't figure out why our outputs are hidden
reconfigure_loglevels()


@asynccontextmanager
async def lifespan_logging(app):
    reconfigure_loglevels()

    # Silence the very annoying ones
    logging.getLogger("chardet.charsetprober").setLevel(logging.INFO)
    logging.getLogger("chardet.universaldetector").setLevel(logging.INFO)
    logging.getLogger("hpack").setLevel(logging.WARNING)
    logging.getLogger("httpcore.http11").setLevel(logging.INFO)
    logging.getLogger("httpcore.connection").setLevel(logging.INFO)
    logging.getLogger("httpx").setLevel(logging.INFO)
    logging.getLogger("markdown_it.rules_block").setLevel(logging.INFO)
    logging.getLogger("pdfminer").setLevel(logging.INFO)
    logging.getLogger("PIL.Image").setLevel(logging.INFO)
    logging.getLogger("PIL.TiffImagePlugin").setLevel(logging.INFO)
    logging.getLogger("pypandoc").setLevel(logging.ERROR)
    logging.getLogger("pypdf").setLevel(logging.CRITICAL)
    logging.getLogger("unstructured").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)
    logging.getLogger("urllib3.connectionpool").setLevel(logging.WARNING)

    yield

    root_logger = logging.getLogger()
    root_logger.setLevel(logging.WARNING)
    root_logger.handlers = []


@asynccontextmanager
async def lifespan_generic(app):
    # This is set if we're running in some PyInstaller configs (--onefile, I think)
    if hasattr(sys, '_MEIPASS'):
        # Our configure script puts pandoc in the top-level directory, so go there
        os.environ.setdefault('PYPANDOC_PANDOC',
                              os.path.join(os.path.dirname(os.path.abspath(__file__)), 'pandoc'))

        # Kick the tires on pypandoc, make sure it's working correctly
        print(pypandoc.get_pandoc_version())
        print(pypandoc.get_pandoc_path())
        print(pypandoc.get_pandoc_formats())

    # opt out of telemetry
    # https://github.com/Unstructured-IO/unstructured/issues/2549
    os.environ["SCARF_NO_ANALYTICS"] = "true"
    os.environ["DO_NOT_TRACK"] = "true"

    async with lifespan_logging(app):
        yield


async def run_ingest(import_files_dir, import_suffix_filter, files_offset, files_count, data_dir):
    async with lifespan_generic(None):
        def _generate_filenames(rootpath: str):
            for dirpath, _, filenames in os.walk(rootpath):
                for file in filenames:
                    full_filepath = os.path.join(dirpath, file)
                    if import_suffix_filter:
                        n = len(import_suffix_filter)
                        if full_filepath[-n:] != import_suffix_filter:
                            continue

                    relative_dirpath = os.path.relpath(dirpath, rootpath)
                    if relative_dirpath:
                        yield os.path.join(relative_dirpath, file)
                    else:
                        yield file

        # TODO: Are we supposed to return an Iterable or Iterator?
        def sliced_filenames(rootpath: str):
            sorted_filenames = sorted(_generate_filenames(rootpath))
            logger.info(f"{rootpath}: Slicing files {files_offset} - {files_offset + files_count} "
                        f"of {len(sorted_filenames)} total")

            for index, full_filename in list(enumerate(sorted_filenames))[files_offset:files_offset + files_count]:
                yield f"#{index}", full_filename

        # TODO: We don't actually need to load anything, do we?
        knowledge = get_knowledge().load_shards_from(data_dir)
        return await ingest.filesystem.bulk_loader(
            sliced_filenames(import_files_dir),
            knowledge)


@click.command()
# TODO: Combine this with import-suffix-filter
@click.argument('import_files_dir', type=click.Path(exists=True))
@click.option('--import-suffix-filter', default='',
              help='For filtering out filenames, e.g. \".mobi\"')
@click.option('--skip', default=0)
@click.option('--count', default=2)
@click.option('--data-dir', default='data/',
              help='Filesystem directory to store/read data from')
@click.option('--log-level', default='DEBUG',
              type=click.Choice(['DEBUG', 'INFO', 'WARNING', 'ERROR', 'FATAL'], case_sensitive=False),
              help='loglevel to pass to Python `logging`')
def main(import_files_dir, import_suffix_filter, skip, count, data_dir, log_level):
    numeric_log_level = getattr(logging, str(log_level).upper(), None)
    logging.getLogger().setLevel(level=numeric_log_level)

    pprint(asyncio.run(
        run_ingest(import_files_dir, import_suffix_filter, skip, count, data_dir)
    ), indent=2, width=120)


if __name__ == '__main__':
    main()
