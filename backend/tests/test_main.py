import os
os.environ["ECHORA_BACKEND_TOKEN"] = "test-token"

from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)

def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"ok": True}

def test_delete_not_supported():
    r = client.delete("/api/rounds/123", headers={"x-echora-token": "test-token"})
    assert r.status_code == 405
