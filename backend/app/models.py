from pydantic import BaseModel, Field
from typing import Optional
from datetime import datetime
from enum import Enum

class RoundMode(str, Enum):
    echora = "echora"
    spoken = "spoken"

class PlacementMethod(str, Enum):
    lidarDepth = "lidarDepth"
    raycastExistingPlane = "raycastExistingPlane"
    raycastEstimatedPlane = "raycastEstimatedPlane"
    planeIntersection = "planeIntersection"
    fixedDepthFallback = "fixedDepthFallback"
    manualTap = "manualTap"

class RoundResult(BaseModel):
    id: str
    participantId: str
    mode: RoundMode
    objectLabel: str
    durationSeconds: float
    success: bool
    isPractice: bool
    headTrackingUsed: bool
    placement: PlacementMethod
    startedAt: datetime
    appVersion: str

class StudyStats(BaseModel):
    participants: int
    echoraRounds: int
    spokenRounds: int
    medianEchoraSeconds: Optional[float] = None
    medianSpokenSeconds: Optional[float] = None
    meanEchoraSeconds: Optional[float] = None
    meanSpokenSeconds: Optional[float] = None
    speedup: Optional[float] = None
