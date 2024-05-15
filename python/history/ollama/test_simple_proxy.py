from fastapi.testclient import TestClient

from history.ollama.simple_proxy import app

client = TestClient(app)

def test_proxy_read():
    """
    TODO: This doesn't actually test anything with the actual FastAPI app we wrote.
    """
    response = client.get(
        "/not-implemented",
    )
    assert response.status_code == 404
