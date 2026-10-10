from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from app.config import CORS_ORIGIN, ECHORA_BACKEND_TOKEN
from app.tiger_client import TigerClient
from app.models import RoundResult, StudyStats

app = FastAPI(title="Echora Backend", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[CORS_ORIGIN] if CORS_ORIGIN != "*" else ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
async def startup_event():
    client = TigerClient()
    # Create hypertable if not exists
    try:
        await client.create_rounds_table()
    except Exception:
        # Non-fatal for demo; table may already exist
        pass

@app.get("/health")
def health():
    return {"ok": True}

def _check_token(x_echora_token: str = Header(...)):
    if x_echora_token != ECHORA_BACKEND_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")

@app.post("/api/rounds")
async def create_round(result: RoundResult, x_echora_token: str = Header(...)):
    _check_token(x_echora_token)
    client = TigerClient()
    # idempotent existence check
    exists = await client.exists(result.id)
    if exists:
        return {"id": result.id, "status": "exists"}
    row = result.model_dump(by_alias=True)
    await client.ingest(row)
    return {"id": result.id, "status": "created"}

@app.get("/api/rounds")
async def list_rounds(limit: int = Query(50, ge=1, le=200), offset: int = Query(0, ge=0)):
    client = TigerClient()
    rows = await client.list_rounds(limit=limit, offset=offset)
    return {"results": rows}

@app.get("/api/stats")
async def get_stats():
    client = TigerClient()
    agg = await client.aggregate({"is_practice": False, "success": True})
    # Simplified derivation; full StudyStats computation to be completed
    return {"aggregated": agg}

@app.delete("/api/rounds/{round_id}")
async def delete_round(round_id: str, x_echora_token: str = Header(...)):
    _check_token(x_echora_token)
    raise HTTPException(status_code=405, detail="Delete not supported for insert-only table")
