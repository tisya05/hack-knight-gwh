# Echora backend (owner: Moon)

Not implemented yet. Moon builds this; the contract below is copied from
`docs/CONTRACT.md` (that file wins if they ever disagree).

### 4.8 Moon: Backend (`backend/`)
See Part 5. FastAPI + **Tiger Data** (Tiger Cloud: hosted PostgreSQL with TimescaleDB). Deploy the API to a public host (Render, Railway, or Fly) so venue Wi-Fi client isolation can't break phone-to-laptop traffic. Fallback: run on a laptop behind a Cloudflare tunnel.

Why Tiger Data instead of SQLite: free app hosts often wipe the server disk on restart/redeploy, which would erase a SQLite file mid-weekend; a hosted database survives that. Postgres also has medians built in (`percentile_cont`). It enters us in the MLH "Best Use of Tiger Data" track.

Database plan (verify exact syntax against current Tiger Data docs):
- Connection string in env var `DATABASE_URL` (Tiger Cloud console). Never commit it. Postgres driver: psycopg 3 or asyncpg.
- Table `rounds`: one column per `RoundResult` field (snake_case in SQL; the API stays camelCase). Make it a hypertable on `started_at`.
- Idempotency: TimescaleDB requires unique constraints on a hypertable to include the time column, so use `UNIQUE (id, started_at)` and `INSERT ... ON CONFLICT (id, started_at) DO NOTHING`; 201 if inserted, 200 if it already existed. Safe because the app always resends the same `startedAt` for a given `id`.
- `/api/stats`: plain SQL. Filter `success AND NOT is_practice`; medians with `percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_seconds)` per mode; `participants` = participant ids that have rows in both modes (`GROUP BY participant_id HAVING COUNT(DISTINCT mode) = 2`).
- pytest for the stats rules against a throwaway database (a separate Tiger Cloud service or a local TimescaleDB Docker container).
- Dashboard extra: a continuous aggregate (e.g. hourly rounds and mean time per mode) for a "results over the weekend" chart. Medians inside continuous aggregates need the TimescaleDB Toolkit (`percentile_agg`); check it is available on our Tiger Cloud plan, otherwise compute medians live (the data is tiny).

Stretch, after M3 (strongest Tiger Data story, needs an additive contract change agreed by Tisya + Moon): per-round trajectories. The coordinator samples angle-to-target and distance at 5-10 Hz during a round; a hypertable `round_samples(round_id, t, mode, angle_deg, distance_m)` stores them via `POST /api/rounds/{id}/samples`; the dashboard shows median |angle| over time per mode ("how fast people turn toward the object with Echora vs spoken directions").

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

## Notes for the iOS client
- `placement` is one of: `lidarDepth`, `raycastExistingPlane`, `raycastEstimatedPlane`,
  `planeIntersection`, `fixedDepthFallback`, `manualTap` (contract v1.1 added `lidarDepth`).
- `ios/Echora/Telemetry/TelemetryClient.swift` encodes `RoundResult` with default
  camelCase keys and `.iso8601` dates, sends `X-Echora-Token` on writes.
- `ping()` hits `GET /health`; the app polls it every 10 s.
- Keep the base URL in `ios/Echora/App/Config.swift` (`Config.backendBaseURL`),
  not in an xcconfig (`//` is a comment there).
