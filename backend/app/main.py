from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from app.config import CORS_ORIGIN, ECHORA_BACKEND_TOKEN
from app.tiger_client import TigerClient
from app.models import RoundResult, StudyStats, RoundSample
from typing import List

app = FastAPI(title="Echora Backend", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[CORS_ORIGIN] if CORS_ORIGIN != "*" else ["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

client = TigerClient()

@app.on_event("startup")
async def startup_event():
    try:
        await client.create_rounds_table()
    except Exception:
        pass

@app.on_event("shutdown")
async def shutdown_event():
    await client.close()

@app.get("/health")
def health():
    return {"ok": True}

def _check_token(x_echora_token: str = Header(...)):
    if not ECHORA_BACKEND_TOKEN:
        raise HTTPException(status_code=500, detail="Server not configured")
    if x_echora_token != ECHORA_BACKEND_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid token")

@app.post("/api/rounds")
async def create_round(result: RoundResult, x_echora_token: str = Header(...)):
    _check_token(x_echora_token)
    exists = await client.exists(result.id)
    if exists:
        return {"id": result.id, "status": "exists"}
    row = {
        "id": result.id,
        "participantId": result.participantId,
        "mode": result.mode.value,
        "objectLabel": result.objectLabel,
        "durationSeconds": result.durationSeconds,
        "success": result.success,
        "isPractice": result.isPractice,
        "headTrackingUsed": result.headTrackingUsed,
        "placement": result.placement.value,
        "startedAt": result.startedAt,
        "appVersion": result.appVersion,
    }
    await client.ingest(row)
    return {"id": result.id, "status": "created"}

@app.get("/api/rounds")
async def list_rounds(limit: int = Query(50, ge=1, le=200), offset: int = Query(0, ge=0)):
    rows = await client.list_rounds(limit=limit, offset=offset)
    # Return camelCase as API contract
    return {"results": rows}

@app.get("/api/stats")
async def get_stats():
    agg = await client.aggregate_stats()
    stats = StudyStats(
        participants=agg["participants"],
        echoraRounds=agg["echoraRounds"],
        medianEchoraSeconds=agg["medianEchoraSeconds"],
        meanEchoraSeconds=agg["meanEchoraSeconds"],
    )
    return stats

@app.delete("/api/rounds/{round_id}")
async def delete_round(round_id: str, x_echora_token: str = Header(...)):
    _check_token(x_echora_token)
    # Simple delete for cleanup
    pool = await client._get_pool()
    async with pool.acquire() as conn:
        await conn.execute("DELETE FROM public.rounds WHERE id = $1", round_id)
    return {"deleted": round_id}

@app.post("/api/rounds/{round_id}/samples")
async def create_samples(round_id: str, samples: List[RoundSample], x_echora_token: str = Header(...)):
    _check_token(x_echora_token)
    sample_dicts = [
        {
            "secondsSinceStart": s.secondsSinceStart,
            "mode": s.mode.value,
            "angleDegrees": s.angleDegrees,
            "distanceMeters": s.distanceMeters,
            "headYawDegrees": s.headYawDegrees,
        }
        for s in samples
    ]
    await client.ingest_samples(round_id, sample_dicts)
    return {"roundId": round_id, "count": len(samples)}

@app.get("/api/rounds/{round_id}/samples")
async def get_samples(round_id: str):
    rows = await client.list_samples(round_id)
    return rows
