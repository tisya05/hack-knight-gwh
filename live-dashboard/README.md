# Echora live dashboard (owner: Tisya, for now)

A laptop screen that shows a search **as it happens**: the snapshot Gemini saw
with its box, a top-down map of the room (you, your head direction, the phone,
the object, the camera → object ray, your trail), live numbers, and the result.

Built so it works today without anyone else's pieces:
- `server.py`: a tiny relay (Python standard library only). The phone POSTs
  live updates to it; it serves the dashboard and `/live/state`.
- `static/`: the dashboard page (no build step).
- `fake_phone.py`: simulates a search, so the dashboard can be designed and
  rehearsed without a phone.
- The app side is `ios/Echora/App/LiveFeed.swift`, off unless `ECHORA_LIVE_URL` is set.

**Later:** Moon can serve the same `/live/*` endpoints from the backend (and
store frames in Tiger Data); the dashboard then points at it with `?api=`.
Qimin restyles via the CSS variables at the top of `static/styles.css`.

## Run it

```sh
python3 live-dashboard/server.py           # http://localhost:8787
python3 live-dashboard/fake_phone.py        # optional: simulated search (--loop to repeat)
```

Open http://localhost:8787 and make it full screen. `POST /live/reset` clears it
between rehearsals:

```sh
curl -X POST localhost:8787/live/reset
```

## Connect the phone

The phone streams to `ECHORA_LIVE_URL` from your gitignored
`ios/Config/Local.xcconfig`. xcconfig treats `//` as a comment, so put `$()`
between the slashes. Rebuild (Command-R) after changing it.

| Where | Setting | Notes |
|---|---|---|
| Simulator | `ECHORA_LIVE_URL = http:/$()/localhost:8787` | Works out of the box. |
| Venue / anywhere (recommended) | `ECHORA_LIVE_URL = https:/$()/<name>.trycloudflare.com` | Run `cloudflared tunnel --url http://localhost:8787` and copy the https URL it prints. Works even when the Wi-Fi blocks devices from talking to each other. The URL changes each time you start the tunnel. |
| Same Wi-Fi or phone hotspot | `ECHORA_LIVE_URL = http:/$()/<laptop IP>:8787` | Laptop IP: `ipconfig getifaddr en0`. iOS asks for Local Network permission the first time; allow it. |

Optional shared secret: start the server with `ECHORA_LIVE_TOKEN=...`; the app
sends `ECHORA_BACKEND_TOKEN` from `Secrets.xcconfig` as `X-Echora-Token`, so
set both to the same value.

The feed is presentation only: fire-and-forget, about 5 frames/s, never
retried, and it can't slow down or break guidance. If the dashboard is
unreachable the app logs it once and carries on.

## Payloads (the contract for moving this into the backend)

World coordinates are ARKit's: meters, +Y up, -Z = the camera's initial forward.
Angles: `angleDeg` + = object to the RIGHT; `headYawDeg` + = head turned LEFT.

`POST /live/round`
```json
{"event": "start", "roundId": "UUID", "mode": "echora", "objectLabel": "blue mug", "startedAt": 1791000000.0}
{"event": "found", "roundId": "UUID", "mode": "echora", "objectLabel": "blue mug", "durationSeconds": 6.4}
{"event": "cancelled"}
```

`POST /live/locate` (once per Gemini answer)
```json
{"utterance": "where's my mug", "label": "blue mug",
 "box": {"minX": 0.43, "minY": 0.41, "maxX": 0.57, "maxY": 0.59},
 "confidence": 0.99, "placement": "lidarDepth", "latencyMs": 1400,
 "camera": {"x": 0, "y": 0, "z": 0}, "target": {"x": 0.25, "y": -0.25, "z": -0.55},
 "snapshotJPEG": "<base64 upright JPEG>"}
```

`POST /live/frames` (~5 Hz, also between rounds so the map shows you moving)
```json
{"frames": [{
  "t": 1791000001.2, "roundId": "UUID", "mode": "echora", "state": "guiding",
  "elapsed": 2.5, "listener": {"x": 0, "y": 0.3, "z": 0.35}, "forward": {"x": 0, "y": 0, "z": -1},
  "phone": {"x": 0, "y": 0, "z": 0}, "phoneForward": {"x": 0, "y": 0, "z": -1},
  "headYawDeg": 12, "headTracking": true,
  "target": {"x": 0.25, "y": -0.25, "z": -0.55}, "angleDeg": 14, "distanceM": 0.9,
  "cueIntervalS": 0.3, "onTarget": false}]}
```
`roundId`, `mode`, `elapsed`, `target`, `angleDeg`, `distanceM`, `cueIntervalS` and `onTarget` are omitted when they don't apply (outside a round; `cueIntervalS` only in Echora mode).

`GET /live/state` returns `{serverTime, lastPostAt, round, result, locate (+ snapshotVersion), frames}`;
`GET /live/snapshot.jpg` returns the latest snapshot.
