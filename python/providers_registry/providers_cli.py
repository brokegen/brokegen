# https://pyinstaller.org/en/v6.6.0/common-issues-and-pitfalls.html#common-issues
from _util.status import ServerStatusHolder

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
from typing import AsyncIterator

import click
from sqlalchemy import select

import audit
import client
import providers_registry
from _util.json import DatetimeEncoder, CatchAllEncoder, JSONDict, safe_get
from _util.typing import FoundationModelRecordID
from audit.http import AuditDB, get_db as get_audit_db
from client.chat_message import ChatMessage
from client.database import HistoryDB, get_db as get_history_db
from inference.continuation import InferenceOptions
from inference.iterators import tee_to_console_output
from providers.inference_models.orm import FoundationModelRecordOrm
from providers.orm import ProviderLabel, ProviderRecord
from providers.registry import ProviderRegistry, BaseProvider

logger = logging.getLogger(__name__)


async def chat(
        provider: BaseProvider,
        start_chat_with: FoundationModelRecordID,
):
    history_db: HistoryDB = next(get_history_db())
    audit_db: AuditDB = next(get_audit_db())

    messages_list: list[ChatMessage] = []
    inference_model: FoundationModelRecordOrm = history_db.execute(
        select(FoundationModelRecordOrm)
        .where(FoundationModelRecordOrm.id == start_chat_with)
    ).scalar_one()
    inference_options: InferenceOptions = InferenceOptions()

    status_holder: ServerStatusHolder = ServerStatusHolder("Ready")

    while True:
        prompt = input("Enter text (enter submits): ")
        messages_list.append(
            ChatMessage(role="user", content=prompt)
        )

        streaming_result = provider.chat_from(
            messages_list, inference_model, inference_options, status_holder, history_db, audit_db
        )

        def chat_extractor(chunk: JSONDict):
            return safe_get(chunk, "message", "content") or ""

        iter0: AsyncIterator[str] = tee_to_console_output(streaming_result, chat_extractor)

        # Iterate over the whole result, so it prints.
        async for chunk in iter0:
            pass


async def amain(
        provider_type: str,
        provider_id: str | None,
        dump_full_models: bool,
        start_chat: bool,
        start_chat_with: FoundationModelRecordID | None,
        registry: ProviderRegistry,
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

    provider: BaseProvider | None = None
    if provider_id is not None:
        label = ProviderLabel(type=provider_type, id=provider_id)
        provider = await registry.try_make(label)
    else:
        for factory in registry.factories:
            await factory.discover(provider_type, registry)

        for label, candidate_provider in registry.by_label.items():
            if provider_type != label.type:
                continue

            logger.info(f"Defaulting to {label=}")
            provider = candidate_provider
            break

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
        try:
            if start_chat_with is None:
                maybe_model = input("Start chat with model ID: ")
                start_chat_with = int(maybe_model)

            await chat(provider, start_chat_with)

        except ValueError:
            logger.error("Invalid model ID, exiting")


@click.command()
@click.argument('provider-type', type=click.STRING)
@click.argument('provider-id', required=False, type=click.STRING)
@click.option('--dump-full-models', default=False, type=click.BOOL)
@click.option('--start-chat', is_flag=True, type=click.BOOL)
@click.option('--start-chat-with',
              prompt=True, prompt_required=False,
              default=None, type=click.IntRange(1))
def main(
        provider_type: str,
        provider_id: str | None,
        dump_full_models: bool,
        start_chat: bool,
        start_chat_with: FoundationModelRecordID | None,
):
    try:
        asyncio.run(amain(
            provider_type=provider_type,
            provider_id=provider_id,
            dump_full_models=dump_full_models,
            start_chat=start_chat,
            start_chat_with=start_chat_with,
            registry=ProviderRegistry(),
        ))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
