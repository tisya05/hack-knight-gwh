import os
from pathlib import Path

from dotenv import load_dotenv

_BACKEND_ROOT = Path(__file__).resolve().parents[1]
load_dotenv(_BACKEND_ROOT / ".env")

DATABASE_URL = os.getenv("DATABASE_URL", "")
ECHORA_BACKEND_TOKEN = os.getenv("ECHORA_BACKEND_TOKEN", "")
CORS_ORIGIN = os.getenv("CORS_ORIGIN", "*")
