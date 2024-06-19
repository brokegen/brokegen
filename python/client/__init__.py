from fastapi import FastAPI

from . import add_message, add_sequence, chat_message, sequence_events, sequence_get


def install_routes(app: FastAPI) -> None:
    add_message.install_routes(app)
    add_sequence.install_routes(app)
    sequence_events.install_routes(app)
    sequence_get.install_routes(app)
