#!/usr/bin/env python3
"""
Pulls every FBS game involving an SEC team for a given week from ESPN's
public (unofficial) scoreboard endpoint, and upserts the results into the
Supabase `games` table.

Env vars required (set as GitHub Actions secrets):
  SUPABASE_URL          e.g. https://xxxxx.supabase.co
  SUPABASE_SERVICE_KEY  the service_role key (NOT the anon key — this needs
                         write access and must never be shipped to the browser)

Usage:
  python update_scores.py --week 3
  python update_scores.py --week 3 --year 2026
"""

import argparse
import os
import sys
import requests

SEC_TEAMS = {
    "Alabama", "Arkansas", "Auburn", "Florida", "Georgia", "Kentucky", "LSU",
    "Mississippi State", "Missouri", "Oklahoma", "Ole Miss", "South Carolina",
    "Tennessee", "Texas", "Texas A&M", "Vanderbilt",
}

# ESPN display names that are known to differ from this app's canonical names.
# Keep this list intentionally small: anything else is surfaced as a workflow
# failure after valid rows are still upserted, so a new mismatch cannot remain
# silent.
NAME_FIXES = {
    "Mississippi": "Ole Miss",
    "UL Monroe": "Louisiana-Monroe",
}


def normalize(name: str) -> str:
    return NAME_FIXES.get(name, name)


def supabase_headers(service_key: str) -> dict[str, str]:
    return {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
    }


def fetch_known_opponents(base_url: str, service_key: str) -> set[str]:
    """Return the canonical opponent names configured in Supabase."""
    resp = requests.get(
        f"{base_url}/rest/v1/opponent_classification?select=opponent",
        headers=supabase_headers(service_key),
        timeout=20,
    )
    if not resp.ok:
        print(
            f"  ! Supabase opponent lookup failed: {resp.status_code} {resp.text}",
            file=sys.stderr,
        )
        resp.raise_for_status()

    rows = resp.json()
    return {row["opponent"] for row in rows if row.get("opponent")}


def fetch_week(week: int, year: int) -> list[dict]:
    """
    groups=8 is ESPN's internal id for the SEC; scoped this way the
    scoreboard endpoint returns every game involving an SEC team, including
    their non-conference matchups (not just SEC-vs-SEC games).
    """
    url = "https://site.api.espn.com/apis/site/v2/sports/football/college-football/scoreboard"
    params = {"groups": 8, "week": week, "year": year, "seasontype": 2, "limit": 100}
    resp = requests.get(url, params=params, timeout=20)
    resp.raise_for_status()
    return resp.json().get("events", [])


def parse_event(event: dict, week: int) -> dict:
    competition = event["competitions"][0]
    competitors = competition["competitors"]
    home = next(c for c in competitors if c["homeAway"] == "home")
    away = next(c for c in competitors if c["homeAway"] == "away")

    home_name = normalize(
        home["team"]["location"]
        if home["team"].get("location")
        else home["team"]["displayName"]
    )
    away_name = normalize(
        away["team"]["location"]
        if away["team"].get("location")
        else away["team"]["displayName"]
    )

    # groups=8 should return only SEC-involved games. If ESPN ever changes an
    # SEC display name (or the endpoint behavior changes), do not silently drop
    # the event: raise so the workflow is visibly marked failed.
    if home_name not in SEC_TEAMS and away_name not in SEC_TEAMS:
        raise ValueError(
            f"ESPN group=8 event has no recognized SEC team: {away_name} @ {home_name}"
        )

    status = competition.get("status", {}).get("type", {}).get("state")
    home_score = (
        int(home["score"])
        if status != "pre" and home.get("score") not in (None, "")
        else None
    )
    away_score = (
        int(away["score"])
        if status != "pre" and away.get("score") not in (None, "")
        else None
    )

    winner = None
    if (
        status == "post"
        and home_score is not None
        and away_score is not None
        and home_score != away_score
    ):
        winner = home_name if home_score > away_score else away_name

    return {
        "week": week,
        "home": home_name,
        "away": away_name,
        "kickoff_at": event["date"],  # ISO8601, UTC
        "home_score": home_score,
        "away_score": away_score,
        "winner": winner,
    }


def find_unknown_names(rows: list[dict], known_opponents: set[str]) -> list[str]:
    known_names = SEC_TEAMS | known_opponents
    return sorted(
        {
            team
            for row in rows
            for team in (row["home"], row["away"])
            if team not in known_names
        }
    )


def upsert_games(rows: list[dict], base_url: str, service_key: str) -> None:
    if not rows:
        print("  no rows to upsert")
        return
    resp = requests.post(
        f"{base_url}/rest/v1/games?on_conflict=week,away,home",
        headers={
            **supabase_headers(service_key),
            "Content-Type": "application/json",
            "Prefer": "resolution=merge-duplicates",
        },
        json=rows,
        timeout=20,
    )
    if not resp.ok:
        print(
            f"  ! Supabase upsert failed: {resp.status_code} {resp.text}",
            file=sys.stderr,
        )
        resp.raise_for_status()
    print(f"  upserted {len(rows)} game(s) for week {rows[0]['week']}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--week", type=int, required=True)
    parser.add_argument("--year", type=int, default=2026)
    args = parser.parse_args()

    base_url = os.environ["SUPABASE_URL"].rstrip("/")
    service_key = os.environ["SUPABASE_SERVICE_KEY"]

    print(f"Fetching week {args.week}, {args.year}...")
    known_opponents = fetch_known_opponents(base_url, service_key)
    print(f"  loaded {len(known_opponents)} configured opponent name(s) from Supabase")

    events = fetch_week(args.week, args.year)
    rows = []
    parse_errors = []

    for event in events:
        try:
            rows.append(parse_event(event, args.week))
        except (KeyError, StopIteration, TypeError, ValueError) as exc:
            event_id = event.get("id", "unknown")
            message = f"event {event_id}: {exc}"
            parse_errors.append(message)
            print(f"::error title=ESPN event parse failure::{message}", file=sys.stderr)

    print(f"  found {len(rows)} recognized SEC-involved game(s)")

    unknown_names = find_unknown_names(rows, known_opponents)
    for name in unknown_names:
        print(
            f"::error title=Unrecognized ESPN team name::"
            f"{name!r} is not an SEC team or opponent_classification name. "
            f"Add a deliberate NAME_FIXES alias or correct the database seed.",
            file=sys.stderr,
        )

    # Preserve every valid score/schedule row even when one event needs human
    # attention. The run is marked failed *after* the upsert so ingestion is
    # not held hostage by one naming/configuration problem.
    upsert_games(rows, base_url, service_key)

    if parse_errors or unknown_names:
        problems = len(parse_errors) + len(unknown_names)
        raise RuntimeError(
            f"score ingestion completed with {problems} validation problem(s); "
            "see the annotated errors above"
        )


if __name__ == "__main__":
    main()
