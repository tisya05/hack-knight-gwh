import os
from unittest.mock import AsyncMock, MagicMock

os.environ["ECHORA_BACKEND_TOKEN"] = "test-token"

import pytest
from fastapi.testclient import TestClient
from app.main import app
from app.main import client as database_client


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(database_client, "create_rounds_table", AsyncMock())
    monkeypatch.setattr(database_client, "close", AsyncMock())
    return TestClient(app)


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"ok": True}


def test_delete_round(client, monkeypatch):
    connection = AsyncMock()
    pool = MagicMock()
    pool.acquire.return_value.__aenter__.return_value = connection
    monkeypatch.setattr(
        database_client,
        "_get_pool",
        AsyncMock(return_value=pool),
    )

    r = client.delete("/api/rounds/123", headers={"x-echora-token": "test-token"})

    assert r.status_code == 200
    assert r.json() == {"deleted": "123"}
    connection.execute.assert_awaited_once_with(
        "DELETE FROM public.rounds WHERE id = $1",
        "123",
    )
