from fastapi import FastAPI

from . import database, routes_generate, routes_message, routes_model, routes_sequence


def install_routes(app: FastAPI):
    seq_router = routes_sequence.construct_router()
    app.include_router(seq_router)
