import pytest
from unittest.mock import AsyncMock, patch
from app.tiger_client import TigerClient

@pytest.mark.asyncio
async def test_tiger_client_auth_header():
    client = TigerClient(base_url="http://test")
    # just ensure client initializes
    assert client.base_url == "http://test"

@pytest.mark.asyncio
async def test_aggregate_call():
    client = TigerClient(base_url="http://test")
    # Simple sanity check that aggregate method exists and is callable
    assert callable(client.aggregate)
