import os
from dotenv import load_dotenv

load_dotenv()

DATABASE_URL = os.getenv("DATABASE_URL", "")
ECHORA_BACKEND_TOKEN = os.getenv("ECHORA_BACKEND_TOKEN", "")
CORS_ORIGIN = os.getenv("CORS_ORIGIN", "*")
