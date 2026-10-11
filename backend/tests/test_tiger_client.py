from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.tiger_client import TigerClient


@pytest.mark.asyncio
async def test_tiger_client_uses_explicit_dsn():
    client = TigerClient(dsn="postgresql://test")

    assert client.dsn == "postgresql://test"


@pytest.mark.asyncio
async def test_tiger_client_creates_pool_from_dsn():
    pool = AsyncMock()
    with patch("app.tiger_client.asyncpg.create_pool", new=AsyncMock(return_value=pool)) as create_pool:
        client = TigerClient(dsn="postgresql://test")

        result = await client._get_pool()

    assert result is pool
    create_pool.assert_awaited_once_with(
        "postgresql://test",
        min_size=1,
        max_size=5,
        timeout=10,
        command_timeout=30,
    )


@pytest.mark.asyncio
async def test_aggregate_stats_reads_camelcase_keys():
    """Regression: unquoted aliases are folded to lowercase by Postgres,
    so r["echoraRounds"] raised KeyError on a real database."""
    conn = AsyncMock()
    conn.fetch.return_value = [
        {
            "participants": 3,
            "echoraRounds": 5,
            "medianEchoraSeconds": 6.5,
            "meanEchoraSeconds": 7.0,
        }
    ]
    pool = MagicMock()
    pool.acquire.return_value.__aenter__.return_value = conn
    client = TigerClient(dsn="postgresql://test")
    client._pool = pool

    stats = await client.aggregate_stats()
    emitted_sql = conn.fetch.await_args.args[0]

    assert emitted_sql.count('AS "echoraRounds"') == 1
    assert emitted_sql.count('AS "medianEchoraSeconds"') == 1
    assert emitted_sql.count('AS "meanEchoraSeconds"') == 1
    assert stats == {
        "participants": 3,
        "echoraRounds": 5,
        "medianEchoraSeconds": 6.5,
        "meanEchoraSeconds": 7.0,
    }


@pytest.mark.asyncio
async def test_create_tables_drops_legacy_rounds_pkey():
    """The first deploy created rounds with PRIMARY KEY (id), which blocks
    hypertable conversion. Startup must drop it; UNIQUE (id, "startedAt")
    keeps idempotency."""
    conn = AsyncMock()
    pool = MagicMock()
    pool.acquire.return_value.__aenter__.return_value = conn
    client = TigerClient(dsn="postgresql://test")
    client._pool = pool

    await client.create_rounds_table()

    statements = [call.args[0] for call in conn.execute.await_args_list]
    assert any(
        "DROP CONSTRAINT IF EXISTS rounds_pkey" in statement
        for statement in statements
    )


@pytest.mark.asyncio
async def test_create_tables_uses_two_arg_hypertable_calls():
    """Regression: create_hypertable('public','rounds','startedAt') never
    matched the Timescale (relation, time_column) signature, so every
    table silently stayed a plain table."""
    conn = AsyncMock()
    pool = MagicMock()
    pool.acquire.return_value.__aenter__.return_value = conn
    client = TigerClient(dsn="postgresql://test")
    client._pool = pool

    await client.create_rounds_table()

    statements = [call.args[0] for call in conn.execute.await_args_list]
    for expected in (
        "create_hypertable('public.rounds', 'startedAt', migrate_data => TRUE",
        "create_hypertable('public.round_samples', 'receivedAt', migrate_data => TRUE",
        "create_hypertable('public.sightings', 'seenAt', migrate_data => TRUE",
    ):
        assert any(expected in statement for statement in statements), expected


@pytest.mark.asyncio
async def test_list_rounds_selects_quoted_camelcase_columns():
    """list_rounds dicts feed the camelCase API directly, so the SELECT
    must use quoted identifiers to survive Postgres case folding."""
    conn = AsyncMock()
    conn.fetch.return_value = []
    pool = MagicMock()
    pool.acquire.return_value.__aenter__.return_value = conn
    client = TigerClient(dsn="postgresql://test")
    client._pool = pool

    await client.list_rounds()
    emitted_sql = conn.fetch.await_args.args[0]

    for column in (
        '"participantId"',
        '"objectLabel"',
        '"durationSeconds"',
        '"isPractice"',
        '"headTrackingUsed"',
        '"startedAt"',
        '"appVersion"',
    ):
        assert column in emitted_sql
