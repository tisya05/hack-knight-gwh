import asyncio
import asyncpg
import os
from pathlib import Path
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent / ".env")
DATABASE_URL = os.getenv("DATABASE_URL")

async def main():
    if not DATABASE_URL:
        raise RuntimeError("DATABASE_URL not set in backend/.env or the environment")
    try:
        conn = await asyncpg.connect(DATABASE_URL, timeout=10)
        version = await conn.fetchval("SELECT version()")
        print("Postgres connected:", version)
        tables = await conn.fetch("""
            SELECT table_name FROM information_schema.tables 
            WHERE table_schema='public' AND table_name IN ('rounds','round_samples')
        """)
        print("Tables found:", [t['table_name'] for t in tables])
        await conn.close()
        print("OK")
    except Exception as exc:
        detail = str(exc) or type(exc).__name__
        raise RuntimeError(f"Connection failed: {detail}") from exc

asyncio.run(main())
