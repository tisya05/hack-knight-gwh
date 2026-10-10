from app.models import RoundResult, StudyStats, RoundMode, PlacementMethod
from datetime import datetime

def test_round_result_parsing():
    data = {
        "id": "1",
        "participantId": "P01",
        "mode": "echora",
        "objectLabel": "mug",
        "durationSeconds": 5.5,
        "success": True,
        "isPractice": False,
        "headTrackingUsed": True,
        "placement": "lidarDepth",
        "startedAt": "2026-01-01T00:00:00",
        "appVersion": "0.1"
    }
    r = RoundResult.model_validate(data)
    assert r.participantId == "P01"
    assert r.mode == RoundMode.echora

def test_study_stats():
    s = StudyStats(participants=1, echoraRounds=2, spokenRounds=2)
    assert s.participants == 1
