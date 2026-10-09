# Echo backend (owner: Moon)

Not implemented yet. Moon builds this; the contract below is copied from
`docs/CONTRACT.md` (that file wins if they ever disagree).

### 4.8 Moon: Backend (`backend/`)
See Part 5. FastAPI + SQLite. Deploy to a public host (Render, Railway, or Fly) so venue Wi-Fi client isolation can't break phone-to-laptop traffic. Fallback: run on a laptop behind a Cloudflare tunnel.

## Backend API contract (Moon)

Base URL: `Config.backendBaseURL`. JSON is camelCase. Dates ISO 8601 UTC. Writes require header `X-Echo-Token: <shared token>`.

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/health` | none | `{"ok": true}` |
| POST | `/api/rounds` | `RoundResult` | `201 {"id": "..."}`. Idempotent on `id` (re-posting same id returns 200, no duplicate). |
| GET | `/api/rounds?limit=50` | none | `[RoundResult]`, newest first |
| DELETE | `/api/rounds/{id}` | none | `204`. Token required. For junk test rounds. |
| GET | `/api/stats` | none | `StudyStats` |

`RoundResult` JSON example:
```json
{
  "id": "6F1C2E4A-1B2C-4D5E-8F90-123456789ABC",
  "participantId": "P07",
  "mode": "echo",
  "objectLabel": "blue mug",
  "durationSeconds": 6.42,
  "success": true,
  "isPractice": false,
  "headTrackingUsed": true,
  "placement": "raycastExistingPlane",
  "startedAt": "2026-10-10T18:22:05Z",
  "appVersion": "0.3.0"
}
```

Stats rules:
- Exclude `isPractice == true` and `success == false`.
- `participants` = distinct `participantId` with at least one valid round in BOTH modes.
- Medians and means over valid rounds per mode. `speedup = medianSpokenSeconds / medianEchoSeconds`, null if either side has no data.
- Use medians in the headline (robust to one person who got lost).

Implementation: FastAPI, SQLite file, Pydantic models mirroring the Swift structs exactly, CORS open to the dashboard origin, pytest for the stats function. Token from an env var.

## Notes for the iOS client
- `placement` is one of: `lidarDepth`, `raycastExistingPlane`, `raycastEstimatedPlane`,
  `planeIntersection`, `fixedDepthFallback`, `manualTap` (contract v1.1 added `lidarDepth`).
- `ios/Echo/Telemetry/TelemetryClient.swift` encodes `RoundResult` with default
  camelCase keys and `.iso8601` dates, sends `X-Echo-Token` on writes.
- `ping()` hits `GET /health`; the app polls it every 10 s.
- Keep the base URL in `ios/Echo/App/Config.swift` (`Config.backendBaseURL`),
  not in an xcconfig (`//` is a comment there).
