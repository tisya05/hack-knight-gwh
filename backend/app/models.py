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
    participantId: str = Field(alias="participant_id")
    mode: RoundMode
    objectLabel: str = Field(alias="object_label")
    durationSeconds: float = Field(alias="duration_seconds")
    success: bool
    isPractice: bool = Field(alias="is_practice")
    headTrackingUsed: bool = Field(alias="head_tracking_used")
    placement: PlacementMethod
    startedAt: datetime = Field(alias="started_at")
    appVersion: str = Field(alias="app_version")

    model_config = {"populate_by_name": True}

class StudyStats(BaseModel):
    participants: int
    echoraRounds: int = Field(alias="echora_rounds")
    spokenRounds: int = Field(alias="spoken_rounds")
    medianEchoraSeconds: Optional[float] = Field(default=None, alias="median_echora_seconds")
    medianSpokenSeconds: Optional[float] = Field(default=None, alias="median_spoken_seconds")
    meanEchoraSeconds: Optional[float] = Field(default=None, alias="mean_echora_seconds")
    meanSpokenSeconds: Optional[float] = Field(default=None, alias="mean_spoken_seconds")
    speedup: Optional[float] = None

    model_config = {"populate_by_name": True}
