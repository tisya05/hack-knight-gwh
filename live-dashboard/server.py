#!/usr/bin/env python3
"""Echora live relay + dashboard server.

The phone POSTs live updates here; the dashboard page polls /live/state.
Standard library only, so it runs anywhere with Python 3.9+:

    python3 live-dashboard/server.py              # http://localhost:8787
    python3 live-dashboard/server.py --port 9000

Optional shared secret: set ECHORA_LIVE_TOKEN and the phone must send the
same value in the X-Echora-Token header on every POST.

Endpoints (payload shapes are documented in live-dashboard/README.md):
    POST /live/round     round started / found / cancelled
    POST /live/locate    one per Gemini answer: utterance, box, target, snapshot JPEG
    POST /live/frames    batch of live frames (position, direction, angle, ...)
    POST /live/reset     clear everything (handy between rehearsals)
    GET  /live/state     everything the dashboard needs, as JSON
    GET  /live/sightings what Echora remembers since the last reset: Tiger Data via
                         the backend (ECHORA_BACKEND_URL), else this session's Gemini
                         answers. ?all=1 = the whole Tiger Data history
    GET  /live/snapshot.jpg   latest snapshot image
    GET  /               the dashboard (files in ./static)
"""

import argparse
import base64
import collections
import json
import os
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
MAX_FRAMES = 3000          # ~5 min at 10 Hz; the dashboard gets the tail
STATE_FRAMES = 600         # frames returned per /live/state
TOKEN = os.environ.get("ECHORA_LIVE_TOKEN", "")
# Moon's backend (Tiger Data). "off" = only this session's sightings.
BACKEND_URL = os.environ.get("ECHORA_BACKEND_URL", "https://hack-knight-gwh.onrender.com").rstrip("/")
MAX_LOCAL_SIGHTINGS = 50
SIGHTINGS_LIMIT = 20
BACKEND_CACHE_S = 5        # the page polls every few seconds; don't hammer Render
BACKEND_TIMEOUT_S = 4      # Render's free tier can take ~30 s to wake; we fall back meanwhile


class LiveState:
    """In-memory state shared by all requests."""

    def __init__(self):
        self.lock = threading.Lock()
        self.reset()

    def reset(self):
        self.round = None
        self.result = None
        self.locate = None
        self.snapshot_jpeg = b""
        self.snapshot_version = 0
        self.frames = collections.deque(maxlen=MAX_FRAMES)
        self.last_post_at = 0.0
        # Gemini answers seen by this relay (fallback when the backend is unreachable).
        self.local_sightings = collections.deque(maxlen=MAX_LOCAL_SIGHTINGS)
        # Spots from before this are from an older AR session: list them, don't map them.
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


def epoch_seconds(value):
    """Backend dates are ISO 8601 strings; the relay's own are epoch seconds."""
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


class BackendSightings:
    """GET {BACKEND_URL}/api/sightings, cached for a few seconds."""

    def __init__(self):
        self.lock = threading.Lock()
        self.fetched_at = 0.0
        self.sightings = None
        self.error = "not fetched yet"

    def get(self):
        if BACKEND_URL.lower() == "off":
            return None, "off"
        with self.lock:
            if time.time() - self.fetched_at < BACKEND_CACHE_S:
                return self.sightings, self.error
            self.fetched_at = time.time()
            url = f"{BACKEND_URL}/api/sightings?limit={SIGHTINGS_LIMIT}"
            try:
                with urllib.request.urlopen(url, timeout=BACKEND_TIMEOUT_S) as response:
                    rows = json.loads(response.read())
                self.sightings = [self.normalize(row) for row in rows]
                self.error = None
            except (urllib.error.URLError, TimeoutError, ValueError, OSError) as error:
                self.sightings = None
                self.error = str(getattr(error, "reason", error))
            return self.sightings, self.error

    @staticmethod
    def normalize(row):
        return {
            "objectLabel": row.get("objectLabel"),
            "utterance": row.get("utterance"),
            "seenAt": epoch_seconds(row.get("seenAt")),
            "x": row.get("x"),
            "y": row.get("y"),
            "z": row.get("z"),
            "placement": row.get("placement"),
        }


BACKEND = BackendSightings()


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC_DIR, **kwargs)

    # Quieter logs: only POST errors and non-200s.
    def log_message(self, fmt, *args):
        if "/live/state" in self.path or "/live/frames" in self.path:
            return
        super().log_message(fmt, *args)

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Echora-Token")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    # --- helpers ---

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length))

    def authorized(self):
        if not TOKEN:
            return True
        return self.headers.get("X-Echora-Token", "") == TOKEN

    # --- routes ---

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/live/state":
            with STATE.lock:
                payload = STATE.to_json()
            self.send_json(200, payload)
            return
        if path == "/live/snapshot.jpg":
            with STATE.lock:
                image = STATE.snapshot_jpeg
            if not image:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(image)))
            self.end_headers()
            self.wfile.write(image)
            return
        if path == "/live/sightings":
            show_all = "all=1" in self.path
            self.send_json(200, self.sightings_payload(show_all))
            return
        if path == "/health":
            self.send_json(200, {"ok": True})
            return
        super().do_GET()

    def sightings_payload(self, show_all=False):
        backend, backend_error = BACKEND.get()
        with STATE.lock:
            local = list(STATE.local_sightings)
            session_started_at = STATE.session_started_at
        # Fresh panel after /live/reset (demo takes): only what was seen since then.
        # ?all=1 shows the whole Tiger Data history.
        if backend and not show_all:
            backend = [
                s for s in backend
                if s.get("seenAt") is not None and s["seenAt"] >= session_started_at
            ]
        # Tiger Data when it has something; otherwise what this relay saw.
        if backend:
            source, sightings = "tiger", backend
        elif local:
            source, sightings = "session", list(reversed(local))
        else:
            source, sightings = ("tiger" if backend is not None else "session"), []
        return {
            "serverTime": time.time(),
            "source": source,
            "backendError": backend_error,
            "sessionStartedAt": session_started_at,
            "sightings": sightings,
        }

    def do_POST(self):
        path = self.path.split("?")[0]
        if not self.authorized():
            self.send_json(401, {"error": "bad token"})
            return
        try:
            body = self.read_json()
        except (ValueError, json.JSONDecodeError):
            self.send_json(400, {"error": "invalid JSON"})
            return

        with STATE.lock:
            STATE.last_post_at = time.time()

            if path == "/live/frames":
                frames = body.get("frames", [])
                for frame in frames:
                    STATE.frames.append(frame)
                self.send_json(200, {"ok": True, "count": len(frames)})
                return

            if path == "/live/round":
                event = body.get("event")
                if event == "start":
                    STATE.round = body
                    STATE.result = None
                    STATE.frames.clear()
                elif event in ("found", "cancelled"):
                    STATE.result = body
                    if STATE.round is not None:
                        STATE.round = dict(STATE.round, ended=event)
                self.send_json(200, {"ok": True})
                return

            if path == "/live/locate":
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
                self.send_json(200, {"ok": True, "snapshotVersion": STATE.snapshot_version})
                return

            if path == "/live/reset":
                STATE.reset()
                self.send_json(200, {"ok": True})
                return

        self.send_json(404, {"error": "unknown endpoint"})


def main():
    parser = argparse.ArgumentParser(description="Echora live relay + dashboard")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Echora live dashboard: http://localhost:{args.port}")
    print(f"Sightings from: {BACKEND_URL}/api/sightings (ECHORA_BACKEND_URL; 'off' to disable)")
    if TOKEN:
        print("POSTs require the X-Echora-Token header (ECHORA_LIVE_TOKEN is set).")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
