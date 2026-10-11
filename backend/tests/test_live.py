import os
import time
from datetime import datetime, timezone
from unittest.mock import AsyncMock

os.environ["ECHORA_BACKEND_TOKEN"] = "test-token"

import pytest
from fastapi.testclient import TestClient
from app import live
from app.main import app
from app.main import client as database_client

TOKEN = {"x-echora-token": "test-token"}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(database_client, "create_rounds_table", AsyncMock())
    monkeypatch.setattr(database_client, "close", AsyncMock())
    monkeypatch.setattr(live.config, "ECHORA_BACKEND_TOKEN", "test-token")
    live.STATE.reset()
    return TestClient(app)


def test_live_writes_need_the_token(client):
    r = client.post("/live/frames", json={"frames": []})
    assert r.status_code == 401
    r = client.post("/live/reset", headers={"x-echora-token": "wrong"})
    assert r.status_code == 401


def test_round_frames_and_state(client):
    r = client.post("/live/round", headers=TOKEN, json={
        "event": "start", "roundId": "R1", "mode": "echora", "objectLabel": "cup", "startedAt": 1.0,
    })
    assert r.status_code == 200
    r = client.post("/live/frames", headers=TOKEN, json={"frames": [{"t": 1.0, "state": "guiding"}]})
    assert r.json()["count"] == 1

    state = client.get("/live/state").json()
    assert state["round"]["objectLabel"] == "cup"
    assert len(state["frames"]) == 1
    assert state["lastPostAt"] > 0

    client.post("/live/round", headers=TOKEN, json={"event": "found", "durationSeconds": 4.2})
    state = client.get("/live/state").json()
    assert state["round"]["ended"] == "found"
    assert state["result"]["durationSeconds"] == 4.2


def test_locate_stores_snapshot_and_a_session_sighting(client):
    r = client.post("/live/locate", headers=TOKEN, json={
        "utterance": "find my cup", "label": "cup", "placement": "lidarDepth",
        "target": {"x": 0.1, "y": -0.2, "z": -0.5}, "snapshotJPEG": "/9j/AA==",
    })
    assert r.json()["snapshotVersion"] == 1

    image = client.get("/live/snapshot.jpg")
    assert image.status_code == 200
    assert image.headers["content-type"] == "image/jpeg"
    assert client.get("/live/state").json()["locate"]["label"] == "cup"


def test_no_snapshot_is_404(client):
    assert client.get("/live/snapshot.jpg").status_code == 404


def test_sightings_since_reset_from_tiger_data(client, monkeypatch):
    now = datetime.now(timezone.utc)
    old = datetime.fromtimestamp(time.time() - 3600, timezone.utc)
    rows = [
        {"objectLabel": "cup", "utterance": "cup", "seenAt": now, "x": 0, "y": 0, "z": -1, "placement": "lidarDepth"},
        {"objectLabel": "keys", "utterance": "keys", "seenAt": old, "x": 0, "y": 0, "z": -1, "placement": "lidarDepth"},
    ]
    monkeypatch.setattr(live, "_list_sightings", AsyncMock(return_value=rows))
    live.STATE.session_started_at = time.time() - 60

    fresh = client.get("/live/sightings").json()
    assert fresh["source"] == "tiger"
    assert [s["objectLabel"] for s in fresh["sightings"]] == ["cup"]

    history = client.get("/live/sightings?all=1").json()
    assert len(history["sightings"]) == 2


def test_sightings_fall_back_to_the_session_when_the_database_fails(client, monkeypatch):
    monkeypatch.setattr(live, "_list_sightings", AsyncMock(side_effect=RuntimeError("db down")))
    client.post("/live/locate", headers=TOKEN, json={
        "utterance": "find my cup", "label": "cup", "placement": "lidarDepth", "target": {"x": 0, "y": 0, "z": -1},
    })
    payload = client.get("/live/sightings").json()
    assert payload["source"] == "session"
    assert payload["backendError"] == "db down"
    assert [s["objectLabel"] for s in payload["sightings"]] == ["cup"]


def test_pages_are_served_and_the_api_still_wins(client):
    home = client.get("/")
    assert home.status_code == 200
    assert "Echora" in home.text
    results = client.get("/results/")
    assert results.status_code == 200
    assert client.get("/health").json() == {"ok": True}
