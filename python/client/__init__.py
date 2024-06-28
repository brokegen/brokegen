from fastapi import FastAPI

from . import message_add, database, chat_message, sequence_add, sequence_events, sequence_get


def install_routes(app: FastAPI) -> None:
    message_add.install_routes(app)
    sequence_add.install_routes(app)
    sequence_events.install_routes(app)
    sequence_get.install_routes(app)
