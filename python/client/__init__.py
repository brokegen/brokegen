from fastapi import FastAPI

from . import add_message, database, chat_message, sequence_add, sequence_events, sequence_get


def install_routes(app: FastAPI) -> None:
    add_message.install_routes(app)
    sequence_add.install_routes(app)
    sequence_events.install_routes(app)
    sequence_get.install_routes(app)
