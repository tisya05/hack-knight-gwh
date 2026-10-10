import base64
import httpx
from app.config import TIGER_REST_BASE_URL, TIGER_ACCESS_KEY, TIGER_SECRET_KEY

def _auth_header() -> dict[str, str]:
    token = f"{TIGER_ACCESS_KEY}:{TIGER_SECRET_KEY}"
    b64 = base64.b64encode(token.encode()).decode()
    return {"Authorization": f"Basic {b64}"}

class TigerClient:
    def __init__(self, base_url: str = TIGER_REST_BASE_URL):
        self.base_url = base_url.rstrip("/")
        self.headers = {**_auth_header(), "Content-Type": "application/json"}

    def _url(self, path: str) -> str:
        return f"{self.base_url}{path}"

    async def exists(self, row_id: str) -> bool:
        url = self._url("/tables/public/rounds")
        params = {"id": row_id, "limit": 1}
        async with httpx.AsyncClient() as client:
            r = await client.get(url, headers=self.headers, params=params, timeout=10)
            r.raise_for_status()
            data = r.json()
            return bool(data.get("results"))

    async def ingest(self, row: dict) -> dict:
        url = self._url("/tables/public/rounds")
        async with httpx.AsyncClient() as client:
            r = await client.post(url, headers=self.headers, json=row, timeout=10)
            r.raise_for_status()
            return r.json()

    async def list_rounds(self, limit: int = 50, offset: int = 0) -> list[dict]:
        url = self._url("/tables/public/rounds")
        params = {"limit": limit, "offset": offset, "order_by": "started_at.desc"}
        async with httpx.AsyncClient() as client:
            r = await client.get(url, headers=self.headers, params=params, timeout=10)
            r.raise_for_status()
            return r.json().get("results", [])

    async def aggregate(self, filters: dict) -> dict:
        url = self._url("/tables/public/rounds/aggregate")
        body = {
            "filters": filters,
            "group_by": ["participant_id", "mode"],
            "aggregations": {
                "rounds_count": "count",
                "median_duration_seconds": "median(duration_seconds)",
                "mean_duration_seconds": "avg(duration_seconds)"
            }
        }
        async with httpx.AsyncClient() as client:
            r = await client.get(url, headers=self.headers, json=body, timeout=10)
            r.raise_for_status()
            return r.json()
