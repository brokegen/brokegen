from fastapi import FastAPI

from . import database, routes, add_message, routes_model, add_sequence


def install_routes(app: FastAPI):
    app.include_router(routes.construct_router())
    app.include_router(add_sequence.construct_router())
