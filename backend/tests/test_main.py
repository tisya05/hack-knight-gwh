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

    assert r.status_code == 204
    assert not r.content
    connection.execute.assert_awaited_once_with(
        "DELETE FROM public.rounds WHERE id = $1",
        "123",
    )


def test_create_round_returns_created_status(client, monkeypatch):
    monkeypatch.setattr(database_client, "exists", AsyncMock(return_value=False))
    ingest = AsyncMock()
    monkeypatch.setattr(database_client, "ingest", ingest)
    payload = {
        "id": "round-1",
        "participantId": "P01",
        "mode": "echora",
        "objectLabel": "mug",
        "durationSeconds": 5.5,
        "success": True,
        "isPractice": False,
        "headTrackingUsed": True,
        "placement": "lidarDepth",
        "startedAt": "2026-10-10T18:22:05Z",
        "appVersion": "0.1.0",
    }

    response = client.post(
        "/api/rounds",
        json=payload,
        headers={"x-echora-token": "test-token"},
    )

    assert response.status_code == 201
    assert response.json() == {"id": "round-1", "status": "created"}
    ingest.assert_awaited_once()
