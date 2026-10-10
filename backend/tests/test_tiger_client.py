from unittest.mock import AsyncMock, patch

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
