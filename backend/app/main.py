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

def round_result_to_tiger_row(result: RoundResult) -> dict:
    return {
        "id": result.id,
        "participant_id": result.participantId,
        "mode": result.mode.value,
        "object_label": result.objectLabel,
        "duration_seconds": result.durationSeconds,
        "success": result.success,
        "is_practice": result.isPractice,
        "head_tracking_used": result.headTrackingUsed,
        "placement": result.placement.value,
        "started_at": result.startedAt.isoformat(),
        "app_version": result.appVersion,
    }

def tiger_row_to_api(row: dict) -> dict:
    return {
        "id": row.get("id"),
        "participantId": row.get("participant_id"),
        "mode": row.get("mode"),
        "objectLabel": row.get("object_label"),
        "durationSeconds": row.get("duration_seconds"),
        "success": row.get("success"),
        "isPractice": row.get("is_practice"),
        "headTrackingUsed": row.get("head_tracking_used"),
        "placement": row.get("placement"),
        "startedAt": row.get("started_at"),
        "appVersion": row.get("app_version"),
    }

@app.post("/api/rounds")
async def create_round(result: RoundResult, x_echora_token: str = Header(...)):
    _check_token(x_echora_token)
    client = TigerClient()
    # idempotent existence check
    exists = await client.exists(result.id)
    if exists:
        return {"id": result.id, "status": "exists"}
    row = round_result_to_tiger_row(result)
    await client.ingest(row)
    return {"id": result.id, "status": "created"}

@app.get("/api/rounds")
async def list_rounds(limit: int = Query(50, ge=1, le=200), offset: int = Query(0, ge=0)):
    client = TigerClient()
    rows = await client.list_rounds(limit=limit, offset=offset)
    return {"results": [tiger_row_to_api(r) for r in rows]}

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
