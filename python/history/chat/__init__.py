from fastapi import FastAPI

from . import database, routes_generate, routes_message, routes_model, routes_sequence


def install_routes(app: FastAPI):
    app.include_router(routes_generate.construct_router())
    app.include_router(routes_sequence.construct_router())
