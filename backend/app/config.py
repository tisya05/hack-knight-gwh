import os
from dotenv import load_dotenv

load_dotenv()

TIGER_REST_BASE_URL = os.getenv("TIGER_REST_BASE_URL", "https://console.cloud.tigerdata.com/public/api/v1")
TIGER_ACCESS_KEY = os.getenv("TIGER_ACCESS_KEY", "")
TIGER_SECRET_KEY = os.getenv("TIGER_SECRET_KEY", "")
ECHORA_BACKEND_TOKEN = os.getenv("ECHORA_BACKEND_TOKEN", "")
CORS_ORIGIN = os.getenv("CORS_ORIGIN", "*")
