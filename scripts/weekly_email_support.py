"""Small, Commissioner-owned helpers for weekly publication verification."""
from __future__ import annotations

import hashlib
import json
from decimal import Decimal
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

ET = ZoneInfo("America/New_York")
PR_FLOORS_BY_SEASON = {
    2026: {
        "QB": 16, "RB": 28, "WR": 50, "TE": 18, "PK": 16, "PN": 16,
        "DT": 38, "DE": 40, "LB": 38, "CB": 38, "S": 38,
    },
}


def rows(value):
    return value if isinstance(value, list) else [value] if isinstance(value, dict) else []


def mfl(kind, season, league, week):
    params = {"TYPE": kind, "JSON": "1"}
    if kind != "nflSchedule":
        params["L"] = league
    if kind != "leagueStandings":
        params["W"] = week
    url = f"https://api.myfantasyleague.com/{season}/export?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Analytics-Fantasy-Labs-completion-report", "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=45) as response:
        payload = json.load(response)
    if kind not in payload:
        raise ValueError(f"MFL {kind} unavailable")
    return payload[kind]


def snapshot(feed, season, league, week):
    if str(feed.get("week")) != str(week):
        raise ValueError("Player-score feed has the wrong week")
    scores = {}
    for player in rows(feed.get("playerScore")):
        player_id = str(player["id"])
        value = Decimal(str(player["score"]))
        if not player_id or not value.is_finite() or player_id in scores:
            raise ValueError("Invalid or duplicate player score")
        scores[player_id] = "0" if value == 0 else format(value.normalize(), "f")
    if not scores:
        raise ValueError("Player-score feed is empty")
    digest = hashlib.sha256(json.dumps(scores, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"season": season, "league_id": league, "week": week, "digest": digest, "scores": scores}


def priced_rank(position, rank, season):
    floors = PR_FLOORS_BY_SEASON.get(season)
    if floors is None:
        raise ValueError(f"PR starter floors are not configured for {season}")
    floor = floors.get(position)
    if floor is None or rank is None:
        return None
    rounded = round(float(rank) * 2) / 2
    return min(max(rounded, 1), floor)
