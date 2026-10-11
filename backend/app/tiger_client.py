import logging

import asyncpg
from app.config import DATABASE_URL

logger = logging.getLogger(__name__)

class TigerClient:
    def __init__(self, dsn: str | None = None):
        self.dsn = dsn if dsn is not None else DATABASE_URL
        self._pool = None

    async def _get_pool(self):
        if self._pool is None:
            if not self.dsn:
                raise RuntimeError("DATABASE_URL not set")
            self._pool = await asyncpg.create_pool(
                self.dsn,
                min_size=1,
                max_size=5,
                timeout=10,
                command_timeout=30,
            )
        return self._pool

    async def close(self):
        if self._pool:
            await self._pool.close()

    async def create_rounds_table(self) -> None:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS public.rounds (
                    id UUID NOT NULL,
                    "participantId" TEXT,
                    mode TEXT,
                    "objectLabel" TEXT,
                    "durationSeconds" DOUBLE PRECISION,
                    success BOOLEAN,
                    "isPractice" BOOLEAN,
                    "headTrackingUsed" BOOLEAN,
                    placement TEXT,
                    "startedAt" TIMESTAMPTZ NOT NULL,
                    "appVersion" TEXT
                );
            """)
            # Migrate pre-fix tables whose unquoted columns were folded to
            # lowercase by Postgres (e.g. participantid). Idempotent: each
            # rename only runs if the lowercase column still exists.
            await conn.execute("""
                DO $$
                BEGIN
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'rounds' AND column_name = 'participantid') THEN
                        ALTER TABLE public.rounds RENAME COLUMN participantid TO "participantId";
                    END IF;
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'rounds' AND column_name = 'objectlabel') THEN
                        ALTER TABLE public.rounds RENAME COLUMN objectlabel TO "objectLabel";
                    END IF;
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'rounds' AND column_name = 'durationseconds') THEN
                        ALTER TABLE public.rounds RENAME COLUMN durationseconds TO "durationSeconds";
                    END IF;
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'rounds' AND column_name = 'ispractice') THEN
                        ALTER TABLE public.rounds RENAME COLUMN ispractice TO "isPractice";
                    END IF;
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'rounds' AND column_name = 'headtrackingused') THEN
                        ALTER TABLE public.rounds RENAME COLUMN headtrackingused TO "headTrackingUsed";
                    END IF;
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'rounds' AND column_name = 'startedat') THEN
                        ALTER TABLE public.rounds RENAME COLUMN startedat TO "startedAt";
                    END IF;
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'rounds' AND column_name = 'appversion') THEN
                        ALTER TABLE public.rounds RENAME COLUMN appversion TO "appVersion";
                    END IF;
                END$$;
            """)
            # Drop the pre-fix PRIMARY KEY on id alone: Timescale refuses
            # conversion while any unique constraint lacks the time column.
            # Idempotency is preserved by UNIQUE (id, "startedAt") below.
            # No-op on tables created after the fix (no such constraint).
            await conn.execute("""
                ALTER TABLE public.rounds DROP CONSTRAINT IF EXISTS rounds_pkey;
            """)
            # Convert to a hypertable. Single 'schema.table' relation arg;
            # a three-arg ('public','rounds','startedAt') call never matched
            # the Timescale signature and failed silently. Warn loudly now.
            try:
                await conn.execute("""
                    SELECT create_hypertable('public.rounds', 'startedAt', migrate_data => TRUE, if_not_exists => TRUE);
                """)
            except Exception as exc:
                logger.warning("rounds is a plain table, not a hypertable: %s", exc)
            # Ensure unique constraint for idempotency
            await conn.execute("""
                DO $$
                BEGIN
                    IF NOT EXISTS (
                        SELECT 1 FROM pg_constraint WHERE conname = 'rounds_id_startedat_key'
                    ) THEN
                        ALTER TABLE public.rounds ADD CONSTRAINT rounds_id_startedat_key UNIQUE (id, "startedAt");
                    END IF;
                END$$;
            """)
            # round_samples table
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS public.round_samples (
                    "roundId" UUID,
                    "secondsSinceStart" DOUBLE PRECISION,
                    mode TEXT,
                    "angleDegrees" DOUBLE PRECISION,
                    "distanceMeters" DOUBLE PRECISION,
                    "headYawDegrees" DOUBLE PRECISION,
                    "receivedAt" TIMESTAMPTZ DEFAULT NOW()
                );
            """)
            await conn.execute("""
                DO $$
                BEGIN
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'round_samples' AND column_name = 'roundid') THEN
                        ALTER TABLE public.round_samples RENAME COLUMN roundid TO "roundId";
                    END IF;
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'round_samples' AND column_name = 'secondssincestart') THEN
                        ALTER TABLE public.round_samples RENAME COLUMN secondssincestart TO "secondsSinceStart";
                    END IF;
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'round_samples' AND column_name = 'angledegrees') THEN
                        ALTER TABLE public.round_samples RENAME COLUMN angledegrees TO "angleDegrees";
                    END IF;
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'round_samples' AND column_name = 'distancemeters') THEN
                        ALTER TABLE public.round_samples RENAME COLUMN distancemeters TO "distanceMeters";
                    END IF;
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'round_samples' AND column_name = 'headyawdegrees') THEN
                        ALTER TABLE public.round_samples RENAME COLUMN headyawdegrees TO "headYawDegrees";
                    END IF;
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'round_samples' AND column_name = 'receivedat') THEN
                        ALTER TABLE public.round_samples RENAME COLUMN receivedat TO "receivedAt";
                    END IF;
                    -- Hypertables require a NOT NULL time column.
                    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'round_samples' AND column_name = 'receivedAt' AND is_nullable = 'YES') THEN
                        ALTER TABLE public.round_samples ALTER COLUMN "receivedAt" SET NOT NULL;
                    END IF;
                END$$;
            """)
            try:
                await conn.execute("""
                    SELECT create_hypertable('public.round_samples', 'receivedAt', migrate_data => TRUE, if_not_exists => TRUE);
                """)
            except Exception as exc:
                logger.warning("round_samples is a plain table, not a hypertable: %s", exc)
            # sightings table (v2.3 "Echora remembers"): timeline of where
            # objects were seen, for the dashboard's "Last seen" panel.
            await conn.execute("""
                CREATE TABLE IF NOT EXISTS public.sightings (
                    id UUID NOT NULL,
                    "participantId" TEXT,
                    "objectLabel" TEXT,
                    utterance TEXT,
                    "seenAt" TIMESTAMPTZ NOT NULL,
                    x DOUBLE PRECISION,
                    y DOUBLE PRECISION,
                    z DOUBLE PRECISION,
                    placement TEXT,
                    confidence DOUBLE PRECISION,
                    CONSTRAINT sightings_id_seenat_key UNIQUE (id, "seenAt")
                );
            """)
            try:
                await conn.execute("""
                    SELECT create_hypertable('public.sightings', 'seenAt', migrate_data => TRUE, if_not_exists => TRUE);
                """)
            except Exception as exc:
                logger.warning("sightings is a plain table, not a hypertable: %s", exc)

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
                    id, "participantId", mode, "objectLabel", "durationSeconds",
                    success, "isPractice", "headTrackingUsed", placement, "startedAt", "appVersion"
                ) VALUES (
                    $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11
                ) ON CONFLICT (id, "startedAt") DO NOTHING
            """, row["id"], row["participantId"], row["mode"], row["objectLabel"],
               row["durationSeconds"], row["success"], row["isPractice"],
               row["headTrackingUsed"], row["placement"], row["startedAt"], row["appVersion"])

    async def list_rounds(self, limit: int = 50, offset: int = 0) -> list[dict]:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT id, "participantId", mode, "objectLabel", "durationSeconds",
                        success, "isPractice", "headTrackingUsed", placement, "startedAt", "appVersion"
                FROM public.rounds
                ORDER BY "startedAt" DESC
                LIMIT $1 OFFSET $2
            """, limit, offset)
            return [dict(r) for r in rows]

    async def aggregate_stats(self) -> dict:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT COUNT(DISTINCT "participantId") AS participants,
                       COUNT(*) AS "echoraRounds",
                       percentile_cont(0.5) WITHIN GROUP (ORDER BY "durationSeconds") AS "medianEchoraSeconds",
                       AVG("durationSeconds") AS "meanEchoraSeconds"
                FROM public.rounds
                WHERE success = true AND "isPractice" = false AND mode = 'echora'
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
            await conn.execute(
                'DELETE FROM public.round_samples WHERE "roundId" = $1',
                round_id,
            )
            await conn.executemany("""
                INSERT INTO public.round_samples (
                    "roundId", "secondsSinceStart", mode, "angleDegrees", "distanceMeters", "headYawDegrees"
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
                SELECT "roundId", "secondsSinceStart", mode, "angleDegrees", "distanceMeters", "headYawDegrees"
                FROM public.round_samples
                WHERE "roundId" = $1
                ORDER BY "secondsSinceStart" ASC
            """, round_id)
            return [dict(r) for r in rows]

    async def sighting_exists(self, sighting_id: str) -> bool:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            row = await conn.fetchrow("SELECT 1 FROM public.sightings WHERE id = $1 LIMIT 1", sighting_id)
            return row is not None

    async def ingest_sighting(self, row: dict) -> None:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            await conn.execute("""
                INSERT INTO public.sightings (
                    id, "participantId", "objectLabel", utterance, "seenAt",
                    x, y, z, placement, confidence
                ) VALUES (
                    $1,$2,$3,$4,$5,$6,$7,$8,$9,$10
                ) ON CONFLICT (id, "seenAt") DO NOTHING
            """, row["id"], row["participantId"], row["objectLabel"], row["utterance"],
                row["seenAt"], row["x"], row["y"], row["z"],
                row["placement"], row["confidence"])

    async def list_sightings(self, limit: int = 20) -> list[dict]:
        pool = await self._get_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT id, "participantId", "objectLabel", utterance, "seenAt",
                       x, y, z, placement, confidence
                FROM public.sightings
                ORDER BY "seenAt" DESC
                LIMIT $1
            """, limit)
            return [dict(r) for r in rows]
