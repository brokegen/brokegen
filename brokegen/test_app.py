from fastapi.testclient import TestClient

from .app import app

client = TestClient(app)

def test_proxy_read():
    response = client.get(
        "/not-implemented",
    )
    assert response.status_code == 404
