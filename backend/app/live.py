"""Live dashboard relay (port of live-dashboard/server.py, owner: Tisya).

The phone POSTs what it is doing; the live page at / polls GET /live/state.
Same endpoints and payloads as live-dashboard/README.md, so the app and the page
work unchanged whether the relay runs on a laptop or here on hear-echora.us.
In-memory only (one Render instance): a restart clears the live view, never the
Tiger Data history.
"""

import base64
import collections
import time
from datetime import datetime
from typing import Awaitable, Callable, Optional

from fastapi import APIRouter, Header, HTTPException, Query, Request, Response

from app import config

MAX_FRAMES = 3000          # ~5 min at 10 Hz; the page gets the tail
STATE_FRAMES = 600         # frames returned per /live/state
MAX_LOCAL_SIGHTINGS = 50
SIGHTINGS_LIMIT = 20

router = APIRouter()

# Set by main.py: reads the newest sightings from Tiger Data.
_list_sightings: Optional[Callable[[int], Awaitable[list]]] = None


def configure(list_sightings: Callable[[int], Awaitable[list]]) -> None:
    global _list_sightings
    _list_sightings = list_sightings


class LiveState:
    def __init__(self):
        self.reset()

    def reset(self):
        self.round = None
        self.result = None
        self.locate = None
        self.snapshot_jpeg = b""
        self.snapshot_version = 0
        self.frames = collections.deque(maxlen=MAX_FRAMES)
        self.last_post_at = 0.0
        # Gemini answers seen here (fallback when the database can't be read).
        self.local_sightings = collections.deque(maxlen=MAX_LOCAL_SIGHTINGS)
        # The memory panel lists only sightings since this, so each demo take starts empty.
        self.session_started_at = time.time()

    def to_json(self):
        locate = None
        if self.locate is not None:
            locate = dict(self.locate)
            locate["snapshotVersion"] = self.snapshot_version
        return {
            "serverTime": time.time(),
            "lastPostAt": self.last_post_at,
            "round": self.round,
            "result": self.result,
            "locate": locate,
            "frames": list(self.frames)[-STATE_FRAMES:],
        }


STATE = LiveState()


def _check_live_token(token: Optional[str]) -> None:
    """Same shared secret as the API writes (the app already sends it)."""
    if not config.ECHORA_BACKEND_TOKEN:
        raise HTTPException(status_code=500, detail="Server not configured")
    if token != config.ECHORA_BACKEND_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")


def _epoch_seconds(value) -> Optional[float]:
    if isinstance(value, datetime):
        return value.timestamp()
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


def _normalize_sighting(row: dict) -> dict:
    return {
        "objectLabel": row.get("objectLabel"),
        "utterance": row.get("utterance"),
        "seenAt": _epoch_seconds(row.get("seenAt")),
        "x": row.get("x"),
        "y": row.get("y"),
        "z": row.get("z"),
        "placement": row.get("placement"),
    }


# --- phone -> relay ---

@router.post("/live/frames")
async def post_frames(request: Request, x_echora_token: Optional[str] = Header(None)):
    _check_live_token(x_echora_token)
    body = await request.json()
    frames = body.get("frames", [])
    for frame in frames:
        STATE.frames.append(frame)
    STATE.last_post_at = time.time()
    return {"ok": True, "count": len(frames)}


@router.post("/live/round")
async def post_round(request: Request, x_echora_token: Optional[str] = Header(None)):
    _check_live_token(x_echora_token)
    body = await request.json()
    event = body.get("event")
    if event == "start":
        STATE.round = body
        STATE.result = None
        STATE.frames.clear()
    elif event in ("found", "cancelled"):
        STATE.result = body
        if STATE.round is not None:
            STATE.round = dict(STATE.round, ended=event)
    STATE.last_post_at = time.time()
    return {"ok": True}


@router.post("/live/locate")
async def post_locate(request: Request, x_echora_token: Optional[str] = Header(None)):
    _check_live_token(x_echora_token)
    body = await request.json()
    encoded = body.pop("snapshotJPEG", "")
    if encoded:
        STATE.snapshot_jpeg = base64.b64decode(encoded)
        STATE.snapshot_version += 1
    STATE.locate = body
    target = body.get("target") or {}
    STATE.local_sightings.append({
        "objectLabel": body.get("label"),
        "utterance": body.get("utterance"),
        "seenAt": time.time(),
        "x": target.get("x"),
        "y": target.get("y"),
        "z": target.get("z"),
        "placement": body.get("placement"),
    })
    STATE.last_post_at = time.time()
    return {"ok": True, "snapshotVersion": STATE.snapshot_version}


@router.post("/live/reset")
async def post_reset(x_echora_token: Optional[str] = Header(None)):
    _check_live_token(x_echora_token)
    STATE.reset()
    return {"ok": True}


# --- relay -> page ---

@router.get("/live/state")
async def get_state():
    return STATE.to_json()


@router.get("/live/snapshot.jpg")
async def get_snapshot():
    if not STATE.snapshot_jpeg:
        raise HTTPException(status_code=404, detail="No snapshot yet")
    return Response(
        content=STATE.snapshot_jpeg,
        media_type="image/jpeg",
        headers={"Cache-Control": "no-store"},
    )


@router.get("/live/sightings")
async def get_sightings(show_all: int = Query(0, alias="all")):
    """What Echora remembers since the last reset (?all=1: whole history).
    Tiger Data first; this relay's own Gemini answers if the database can't be read."""
    backend = None
    backend_error = None
    if _list_sightings is not None:
        try:
            rows = await _list_sightings(SIGHTINGS_LIMIT)
            backend = [_normalize_sighting(row) for row in rows]
        except Exception as error:  # database unreachable: fall back, never break the page
            backend_error = str(error)
    else:
        backend_error = "not configured"

    if backend and not show_all:
        backend = [
            s for s in backend
            if s["seenAt"] is not None and s["seenAt"] >= STATE.session_started_at
        ]

    local = list(STATE.local_sightings)
    if backend:
        source, sightings = "tiger", backend
    elif local:
        source, sightings = "session", list(reversed(local))
    else:
        source = "tiger" if backend is not None else "session"
        sightings = []
    return {
        "serverTime": time.time(),
        "source": source,
        "backendError": backend_error,
        "sessionStartedAt": STATE.session_started_at,
        "sightings": sightings,
    }
