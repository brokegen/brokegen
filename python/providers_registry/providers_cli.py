# https://pyinstaller.org/en/v6.6.0/common-issues-and-pitfalls.html#common-issues
if __name__ == '__main__':
    # Doubly needed when working with uvicorn, probably
    # https://github.com/encode/uvicorn/issues/939
    # https://pyinstaller.org/en/latest/common-issues-and-pitfalls.html
    import multiprocessing

    multiprocessing.freeze_support()

import asyncio
import json
import logging
import os
import sqlite3

import click

import audit
import client
import providers_registry
from _util.json import DatetimeEncoder, CatchAllEncoder
from _util.typing import FoundationModelRecordID
from providers.orm import ProviderLabel, ProviderRecord
from providers.registry import ProviderRegistry, BaseProvider

logger = logging.getLogger(__name__)


async def chat(
        start_chat_with: FoundationModelRecordID | None,
):
    pass


async def amain(
        label: ProviderLabel,
        registry: ProviderRegistry,
        dump_full_models: bool,
        start_chat: bool,
        start_chat_with: FoundationModelRecordID | None,
        data_dir: str = "data/",
        dump_provider_record: bool = False,
):
    try:
        audit.http.init_db(f"{data_dir}/audit.db")
        client.database.load_db_models(f"{data_dir}/requests-history.db")

    except sqlite3.OperationalError:
        if not os.path.exists(data_dir):
            logger.fatal(f"Directory does not exist: {data_dir=}")
        else:
            logger.exception(f"Failed to initialize app databases")
        return

    (
        registry
        .register_factory(providers_registry.echo.registry.EchoProviderFactory())
        .register_factory(providers_registry.openai.lm_studio.LMStudioFactory())
        .register_factory(providers_registry.llamafile.registry.LlamafileFactory(['dist']))
        .register_factory(providers_registry.ollama.registry.ExternalOllamaFactory())
        .register_factory(providers_registry.lcp.factory.LlamaCppProviderFactory())
    )

    print("Registered ProviderFactories: " + json.dumps(
        [repr(f) for f in registry.factories],
        indent=2,
    ))
    print()

    provider: BaseProvider | None = await registry.try_make(label)
    if provider is None:
        return

    print(f".available(): {await provider.available()}")
    print()

    if dump_provider_record:
        provider_record: ProviderRecord = await provider.make_record()
        print(".make_record(): " + json.dumps(
            provider_record.model_dump(),
            indent=2,
            cls=DatetimeEncoder,
        ))
        print()

    if dump_full_models:
        print(f".list_models():")
        print(json.dumps(
            [m async for m in provider.list_models()],
            indent=2,
            cls=CatchAllEncoder,
        ))
        print()
    else:
        print(f".list_models():")
        print(json.dumps(
            dict([(m.id, m.human_id) async for m in provider.list_models()]),
            indent=2,
            cls=CatchAllEncoder,
        ))
        print()

    if start_chat:
        if start_chat_with is None:
            start_chat_with = input("Start chat with model ID: ")

        await chat(start_chat_with)


@click.command()
@click.argument('provider-type', type=click.STRING)
@click.argument('provider-id', type=click.STRING)
@click.option('--dump-full-models', default=False, type=click.BOOL)
@click.option('--start-chat', is_flag=True, type=click.BOOL)
@click.option('--start-chat-with',
              prompt=True, prompt_required=False,
              default=None, type=click.IntRange(1))
def main(
        provider_type: str,
        provider_id: str,
        dump_full_models: bool,
        start_chat: bool,
        start_chat_with: FoundationModelRecordID | None,
):
    try:
        asyncio.run(amain(
            ProviderLabel(type=provider_type, id=provider_id),
            ProviderRegistry(),
            dump_full_models=dump_full_models,
            start_chat=start_chat,
            start_chat_with=start_chat_with,
        ))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
