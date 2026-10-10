#!/usr/bin/env python3
"""Simulates the phone streaming one search to the live relay.

Use it to design / test the dashboard without a phone, or to rehearse the video:

    python3 live-dashboard/server.py            # terminal 1
    python3 live-dashboard/fake_phone.py         # terminal 2 (add --loop to repeat)

It sends the same payloads the app's LiveFeed sends: a round start, one locate
(with the repo's mock_table.jpg as the snapshot), ~10 Hz frames while the
"listener" turns their head toward the object, then a FOUND result.
"""

import argparse
import base64
import json
import math
import os
import time
import urllib.request
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SNAPSHOT = os.path.join(REPO, "ios", "Echora", "Resources", "mock_table.jpg")

TARGET = {"x": 0.25, "y": -0.25, "z": -0.55}
PHONE = {"x": 0.0, "y": 0.0, "z": 0.0}
PHONE_FORWARD = {"x": 0.0, "y": 0.0, "z": -1.0}
# standInFront rig: ears 0.35 m behind and 0.30 m above the phone.
LISTENER = {"x": 0.0, "y": 0.30, "z": 0.35}


def post(base, path, payload, token):
    request = urllib.request.Request(
        base + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "X-Echora-Token": token},
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        response.read()


def angle_to_target_degrees(listener, forward):
    """+ = target to the RIGHT of forward (same convention as Geometry)."""
    tx = TARGET["x"] - listener["x"]
    tz = TARGET["z"] - listener["z"]
    cross_y = forward["z"] * tx - forward["x"] * tz
    dot = forward["x"] * tx + forward["z"] * tz
    return math.degrees(math.atan2(-cross_y, dot))


def forward_from_yaw(yaw_degrees):
    """Phone faces -Z; + yaw = head turned LEFT."""
    yaw = math.radians(yaw_degrees)
    return {"x": -math.sin(yaw), "y": 0.0, "z": -math.cos(yaw)}


def run_once(base, token, seconds):
    round_id = str(uuid.uuid4()).upper()
    post(base, "/live/round", {
        "event": "start", "roundId": round_id, "mode": "echora",
        "objectLabel": "blue mug", "startedAt": time.time(),
    }, token)

    with open(SNAPSHOT, "rb") as handle:
        jpeg = base64.b64encode(handle.read()).decode()
    post(base, "/live/locate", {
        "roundId": round_id, "utterance": "where's my mug", "label": "blue mug",
        "box": {"minX": 0.43, "minY": 0.41, "maxX": 0.57, "maxY": 0.59},
        "confidence": 0.99, "placement": "lidarDepth", "latencyMs": 1400,
        "camera": PHONE, "target": TARGET, "snapshotJPEG": jpeg,
    }, token)

    # Head starts looking 40 degrees left, overshoots right, then settles on the mug.
    final_yaw = -math.degrees(math.atan2(TARGET["x"] - LISTENER["x"], -(TARGET["z"] - LISTENER["z"])))
    started = time.time()
    batch = []
    while True:
        elapsed = time.time() - started
        if elapsed > seconds:
            break
        progress = min(1.0, elapsed / (seconds * 0.8))
        wobble = 45 * math.exp(-3 * progress) * math.cos(2.2 * math.pi * progress)
        yaw = final_yaw + wobble + 40 * (1 - progress) ** 3
        forward = forward_from_yaw(yaw)
        angle = angle_to_target_degrees(LISTENER, forward)
        distance = math.hypot(TARGET["x"] - LISTENER["x"], TARGET["z"] - LISTENER["z"])
        t = min(1.0, abs(angle) / 90)
        batch.append({
            "t": time.time(), "roundId": round_id, "mode": "echora", "state": "guiding",
            "elapsed": elapsed, "listener": LISTENER, "forward": forward,
            "phone": PHONE, "phoneForward": PHONE_FORWARD,
            "headYawDeg": yaw, "headTracking": True,
            "target": TARGET, "angleDeg": angle, "distanceM": distance,
            "cueIntervalS": 0.15 + (0.70 - 0.15) * t, "onTarget": abs(angle) < 12,
        })
        if len(batch) >= 2:
            post(base, "/live/frames", {"frames": batch}, token)
            batch = []
        time.sleep(0.1)

    post(base, "/live/round", {
        "event": "found", "roundId": round_id, "mode": "echora",
        "objectLabel": "blue mug", "durationSeconds": round(seconds, 2),
    }, token)


def main():
    parser = argparse.ArgumentParser(description="Fake phone for the Echora live dashboard")
    parser.add_argument("--url", default="http://localhost:8787")
    parser.add_argument("--seconds", type=float, default=8.0)
    parser.add_argument("--loop", action="store_true", help="repeat forever with a pause")
    args = parser.parse_args()
    token = os.environ.get("ECHORA_LIVE_TOKEN", "")

    while True:
        print("Simulating a search…")
        run_once(args.url.rstrip("/"), token, args.seconds)
        print("Found.")
        if not args.loop:
            break
        time.sleep(4)


if __name__ == "__main__":
    main()
