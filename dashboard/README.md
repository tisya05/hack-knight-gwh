# Echora dashboard (code: Moon, design: Qimin)

Static site, no build step. The API it reads is defined in
`backend/README.md` / `docs/CONTRACT.md` Part 5 (copied below).

### Usage

Serve this directory from any static web server:

```sh
python3 -m http.server 8080 --directory dashboard
```

Open `http://localhost:8080/?api=http://localhost:8000` when the API is
served separately. If the dashboard and API share an origin, omit `api`.

The page polls `GET /api/stats` and `GET /api/rounds?limit=10` every 3 seconds.
It shows the median Echora find time, participant count, successful recent
rounds, connection status, and the required footnote:
"Informal booth testing, not a clinical study."

The spoken-directions comparison was removed in contract v2.0, so this
dashboard intentionally displays Echora-only results.
- Projected on a laptop at the booth. Readable from 3 meters. Our GoDaddy domain points here.

## Backend API contract (Moon)

Base URL: `Config.backendBaseURL`. JSON is camelCase. Dates ISO 8601 UTC. Writes require header `X-Echora-Token: <shared token>`.

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
  "mode": "echora",
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
- Medians and means over valid rounds per mode. `speedup = medianSpokenSeconds / medianEchoraSeconds`, null if either side has no data.
- Use medians in the headline (robust to one person who got lost).

Implementation: FastAPI, Tiger Data (hosted PostgreSQL + TimescaleDB, see 4.8), Pydantic models mirroring the Swift structs exactly, CORS open to the dashboard origin, pytest for the stats function. Token and `DATABASE_URL` from env vars.
