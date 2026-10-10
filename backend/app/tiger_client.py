import asyncpg
from app.config import DATABASE_URL

class TigerClient:
    def __init__(self, dsn: str = DATABASE_URL):
        self.dsn = dsn
        self._pool = None

    async def _get_pool(self):
        if self._pool is None:
            if not self.dsn:
                raise RuntimeError("DATABASE_URL not set")
            self._pool = await asyncpg.create_pool(self.dsn, min_size=1, max_size=5)
        return self._pool

    async def close(self):
        if self._pool:
            await self._pool.close()

    async def create_rounds_table(self) -> None:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS public.rounds (
                    id UUID PRIMARY KEY,
                    participantId TEXT,
                    mode TEXT,
                    objectLabel TEXT,
                    durationSeconds DOUBLE PRECISION,
                    success BOOLEAN,
                    isPractice BOOLEAN,
                    headTrackingUsed BOOLEAN,
                    placement TEXT,
                    startedAt TIMESTAMPTZ,
                    appVersion TEXT
                );
            """)
            # Create hypertable if Timescale extension available
            try:
                await conn.execute("""
                    SELECT create_hypertable('public','rounds','startedAt', if_not_exists => TRUE);
                """)
            except Exception:
                pass
            # Ensure unique constraint for idempotency
            await conn.execute("""
                DO $$
                BEGIN
                    IF NOT EXISTS (
                        SELECT 1 FROM pg_constraint WHERE conname = 'rounds_id_startedat_key'
                    ) THEN
                        ALTER TABLE public.rounds ADD CONSTRAINT rounds_id_startedat_key UNIQUE (id, startedAt);
                    END IF;
                END$$;
            """)
            # round_samples table
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS public.round_samples (
                    roundId UUID,
                    secondsSinceStart DOUBLE PRECISION,
                    mode TEXT,
                    angleDegrees DOUBLE PRECISION,
                    distanceMeters DOUBLE PRECISION,
                    headYawDegrees DOUBLE PRECISION,
                    receivedAt TIMESTAMPTZ DEFAULT NOW()
                );
            """)
            try:
                await conn.execute("""
                    SELECT create_hypertable('public','round_samples','receivedAt', if_not_exists => TRUE);
                """)
            except Exception:
                pass

    async def exists(self, row_id: str) -> bool:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            row = await conn.fetchrow("SELECT 1 FROM public.rounds WHERE id = $1 LIMIT 1", row_id)
            return row is not None

    async def ingest(self, row: dict) -> None:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            await conn.execute("""
                INSERT INTO public.rounds (
                    id, participantId, mode, objectLabel, durationSeconds,
                    success, isPractice, headTrackingUsed, placement, startedAt, appVersion
                ) VALUES (
                    $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11
                ) ON CONFLICT (id, startedAt) DO NOTHING
            """, row["id"], row["participantId"], row["mode"], row["objectLabel"],
               row["durationSeconds"], row["success"], row["isPractice"],
               row["headTrackingUsed"], row["placement"], row["startedAt"], row["appVersion"])

    async def list_rounds(self, limit: int = 50, offset: int = 0) -> list[dict]:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT id, participantId, mode, objectLabel, durationSeconds,
                       success, isPractice, headTrackingUsed, placement, startedAt, appVersion
                FROM public.rounds
                ORDER BY startedAt DESC
                LIMIT $1 OFFSET $2
            """, limit, offset)
            return [dict(r) for r in rows]

    async def aggregate_stats(self) -> dict:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT COUNT(DISTINCT participantId) AS participants,
                       COUNT(*) AS echoraRounds,
                       percentile_cont(0.5) WITHIN GROUP (ORDER BY durationSeconds) AS medianEchoraSeconds,
                       AVG(durationSeconds) AS meanEchoraSeconds
                FROM public.rounds
                WHERE success = true AND isPractice = false AND mode = 'echora'
            """)
            r = rows[0]
            return {
                "participants": r["participants"] or 0,
                "echoraRounds": r["echoraRounds"] or 0,
                "medianEchoraSeconds": float(r["medianEchoraSeconds"]) if r["medianEchoraSeconds"] is not None else None,
                "meanEchoraSeconds": float(r["meanEchoraSeconds"]) if r["meanEchoraSeconds"] is not None else None,
            }

    async def ingest_samples(self, round_id: str, samples: list[dict]) -> None:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            await conn.executemany("""
                INSERT INTO public.round_samples (
                    roundId, secondsSinceStart, mode, angleDegrees, distanceMeters, headYawDegrees
                ) VALUES ($1,$2,$3,$4,$5,$6)
                ON CONFLICT DO NOTHING
            """, [
                (round_id, s["secondsSinceStart"], s["mode"], s["angleDegrees"], s["distanceMeters"], s["headYawDegrees"])
                for s in samples
            ])

    async def list_samples(self, round_id: str) -> list[dict]:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT roundId, secondsSinceStart, mode, angleDegrees, distanceMeters, headYawDegrees
                FROM public.round_samples
                WHERE roundId = $1
                ORDER BY secondsSinceStart ASC
            """, round_id)
            return [dict(r) for r in rows]
