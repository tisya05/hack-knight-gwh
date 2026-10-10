from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.config import CORS_ORIGIN
from app.tiger_client import TigerClient

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
