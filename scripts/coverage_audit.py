#!/usr/bin/env python3
"""Audit how well the app's accessibility.cloud catalog covers the stations
listed on brokenlifts.org.

This is a diagnostic, not a CI test: it hits the live network and does fuzzy
name matching across two datasets that use different id and naming schemes, so
its output is an audit aid, not a pass/fail gate.

The token is read from the source tree so the audit stays in sync with the
app:
  - appToken: env ACCESSIBILITY_CLOUD_APP_TOKEN, else Shared/Secrets.swift

Usage:
  python3 scripts/coverage_audit.py
"""

from __future__ import annotations
import json
import os
import re
import sys
import time
import unicodedata
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# transit.accessibility.cloud: flat lists joined by id — keep in sync with
# Shared/AccessibilityCloudClient.swift (TransitAPI).
HOST = "https://transit.accessibility.cloud"
API_ROOT = "/api"
BROKENLIFTS = "https://brokenlifts.org/stationen"


def read_token() -> str:
    if tok := os.environ.get("ACCESSIBILITY_CLOUD_APP_TOKEN"):
        return tok
    secrets = os.path.join(ROOT, "Shared", "Secrets.swift")
    m = re.search(r'accessibilityCloudAppToken\s*=\s*"([^"]+)"', open(secrets).read())
    if not m:
        sys.exit("No appToken: set ACCESSIBILITY_CLOUD_APP_TOKEN or fill Shared/Secrets.swift")
    return m.group(1)


def get(url: str, token: str | None = None, tries: int = 6) -> dict:
    headers = {"User-Agent": "Hissi-coverage-audit"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.load(r)
        except Exception:  # noqa: BLE001 - diagnostic; back off on 403/rate limits
            if attempt == tries - 1:
                raise
            time.sleep(10 * (attempt + 1))
    raise RuntimeError("unreachable")


def fetch_list(token: str, resource: str, select: str) -> list[dict]:
    out: list[dict] = []
    page = 1
    while True:
        url = (f"{HOST}{API_ROOT}/{resource}"
               f"?depth=0&draft=false&trash=false&limit=500&page={page}&{select}")
        data = get(url, token)
        out += data.get("docs", [])
        if not data.get("hasNextPage"):
            break
        page += 1
    return out


def station_names(token: str) -> tuple[int, set[str]]:
    """(elevator count, distinct names of stations that have elevators)."""
    elevators = fetch_list(
        token, "elevators",
        "select%5Blocation%5D%5Bsite%5D=true&select%5Belevator_type%5D=true",
    )
    elevators = [e for e in elevators if e.get("elevator_type") in (None, "elevator")]
    stops = {s["id"]: s for s in fetch_list(token, "stop-places", "select%5Bnormalized_name%5D=true")}
    names = {
        (stops.get((e.get("location") or {}).get("site")) or {}).get("normalized_name") or ""
        for e in elevators
    }
    return len(elevators), names


def fetch_brokenlifts() -> dict[str, str]:
    # brokenlifts.org answers 403 to non-browser user agents.
    req = urllib.request.Request(
        BROKENLIFTS, headers={"User-Agent": "Mozilla/5.0 (compatible; Hissi-coverage-audit)"}
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        html = r.read().decode("utf-8", "replace")
    # id -> display name
    return dict(re.findall(r'/station/(\d+)"[^>]*>\s*([^<]+?)\s*<', html))


def normalize(name: str) -> str:
    # "ß" first — the ascii fold below would drop it ("Seestraße" → "seestrae").
    s = name.replace("ß", "ss")
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    s = s.replace("strasse", "str").replace("bahnhof", "bhf")
    s = re.sub(r"\(berlin\)", " ", s)
    s = re.sub(r"[^a-z0-9]+", " ", s).strip()
    # Drop the transit prefix (U / S / S+U) so "U Foo" matches "S+U Foo".
    s = re.sub(r"^(?:s\s*u|u\s*s|s|u)\s+", "", s).strip()
    return s.replace("lufbrucke", "luftbrucke")  # brokenlifts typo


def is_covered(bl_norm: str, app_norms: set[str]) -> bool:
    if not bl_norm:
        return True
    # Exact, or one side merely appends a suffix ("Bhf", "/Checkpoint…",
    # "S1 U7") to the other.
    return any(
        a == bl_norm or a.startswith(bl_norm + " ") or bl_norm.startswith(a + " ")
        for a in app_norms
    )


def main() -> None:
    token = read_token()
    print("Fetching…", file=sys.stderr)

    lift_count, names = station_names(token)
    brokenlifts = fetch_brokenlifts()
    app_norms = {normalize(n) for n in names}
    app_norms.discard("")

    missing = sorted(
        ((sid, name) for sid, name in brokenlifts.items() if not is_covered(normalize(name), app_norms)),
        key=lambda t: t[1],
    )

    total = len(brokenlifts)
    covered = total - len(missing)
    print(f"\nApp catalog:   {lift_count} lifts across {len(app_norms)} distinct station names")
    print(f"brokenlifts:   {total} stations")
    print(f"Covered:       {covered}/{total} ({100 * covered // total}%)")
    print(f"Missing:       {len(missing)}\n")
    for sid, name in missing:
        print(f"  {sid}  {name}")


if __name__ == "__main__":
    main()
