from pydantic import BaseModel
from typing import Optional
from datetime import datetime
from enum import Enum

class RoundMode(str, Enum):
    echora = "echora"

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
    medianEchoraSeconds: Optional[float] = None
    meanEchoraSeconds: Optional[float] = None

class RoundSample(BaseModel):
    roundId: str
    secondsSinceStart: float
    mode: RoundMode
    angleDegrees: float
    distanceMeters: float
    headYawDegrees: float
