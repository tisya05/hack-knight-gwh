# Echora dashboard (code: Moon, design: Qimin)

Not implemented yet. Static site, no build step. The API it reads is defined in
`backend/README.md` / `docs/CONTRACT.md` Part 5 (copied below).

### 4.9 Moon (build) + Qimin (design): Dashboard (`dashboard/`)
- Static `index.html` + `app.js` + `styles.css`, no build step. Polls `GET /api/stats` and `GET /api/rounds?limit=10` every 3 s.
- Shows: median time with spoken directions, median time with Echora, speedup ("2.4x faster"), number of participants, last 10 rounds, a small footnote "Informal booth testing, not a clinical study."
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

Implementation: FastAPI, SQLite file, Pydantic models mirroring the Swift structs exactly, CORS open to the dashboard origin, pytest for the stats function. Token from an env var.
