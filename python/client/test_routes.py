import json
from http.client import HTTPException

import fastapi
import pytest
from starlette.testclient import TestClient

import client.add_message
import providers.inference_models.database
import providers_registry
from providers.inference_models.database import HistoryDB


@pytest.fixture(scope='session')
def chat_test_app():
    test_app = fastapi.FastAPI()
    client.install_routes(test_app)
    providers_registry.ollama.sequence_extend.install_routes(test_app)

    yield test_app


@pytest.fixture
def test_client(chat_test_app):
    return TestClient(chat_test_app)


@pytest.fixture(scope="function", autouse=True)
def history_db() -> HistoryDB:
    providers.inference_models.database.load_db_models_pytest()
    yield providers.inference_models.database.get_db()
    providers.inference_models.database.SessionLocal = None


def test_early_read(test_client):
    with pytest.raises(HTTPException) as e_info:
        response = test_client.get("/messages/1")


def test_unchecked_write(test_client, history_db):
    response0 = test_client.post("/messages", content=json.dumps({
        "role": "user",
        "content": "test_write_read() is great content",
        "created_at": None,
    }))

    assert response0.status_code == 201
    new_id: int = response0.json()['message_id']
    assert new_id > 0


def test_write_read(test_client):
    test_role = "user"
    test_content = "test_write_read() is great content"

    response0 = test_client.post("/messages", content=json.dumps({
        "role": "user",
        "content": test_content,
        "created_at": None,
    }))

    assert response0.status_code == 201
    new_id: int = response0.json()['message_id']
    assert new_id > 0

    response1 = test_client.get(f"/messages/{new_id}")
    assert response1.json()['content'] == test_content
