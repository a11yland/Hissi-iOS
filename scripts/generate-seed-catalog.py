#!/usr/bin/env python3
"""Generate the bundled seed catalog.

Since the transit.accessibility.cloud migration the seed's job is metadata
backfill — station/source/operator names, coordinates and region, matched by
the operator inventory number — plus gap-station records and the offline
search list. Pre-migration favorites are deleted by the app, not mapped.

Sources:

- **legacy www.accessibility.cloud** (equipment-infos, runs in parallel for a
  transition period): names, descriptions, coordinates, source/operator names
  and — as numeric `originalId` — the operator inventory number. The transit
  API serves none of these at depth=0 (and no geometry at all), which is why
  the seed exists.
- **transit.accessibility.cloud** (Bearer `trtok_…`): which inventory numbers
  and stations exist live — reports unmatched records and decides which
  carried-over gap records are still needed.
- **the bundled seed itself**: "fasta" records (DB elevators absent from the
  legacy API; their static metadata once came from the DB FaSta API, whose
  credentials are retired) are carried over unchanged, "brokenlifts" records
  only while the platform still lacks their station (currently S
  Fredersdorf).

    ACCESSIBILITY_CLOUD_APP_TOKEN=trtok_… \\
    ACCESSIBILITY_CLOUD_LEGACY_TOKEN=… \\
    python3 scripts/generate-seed-catalog.py [output-path]

Before writing, the run checks the result for stations whose records
disagree about where the station is (see report_coordinate_outliers) — since
the app backfills coordinates across a station, one wrong entry misplaces
its siblings too. Diagnostics only: the run never fails on it.

The transit token falls back to `accessibilityCloudAppToken` in
Shared/Secrets.swift; the legacy token must come from the environment.
"""

import json
import math
import os
import re
import sys
import time
import unicodedata
import urllib.request
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO / "Shared" / "Resources" / "seed-catalog.json"
BUNDLED = DEFAULT_OUTPUT  # carry-over source for fasta/brokenlifts records

LEGACY_HOST = "https://www.accessibility.cloud"
# Canonical Berlin/VBB sources of the legacy API ("BVG Elevators (2025)",
# "VBB Anlagen (S-Bahn)", "VBB-Anlagen (DB Regio)").
LEGACY_SOURCE_IDS = "v7c7T5ivwqdbffXQn,Wkd92kW7X2rAsbTdH,ZpdNXw3AJpphwn68T"

TRANSIT_HOST = "https://transit.accessibility.cloud"
TRANSIT_PAGE_SIZE = 500

# Elevators of one station sit within a few hundred metres of each other;
# beyond this the records disagree about where the station is.
COORDINATE_SPREAD_LIMIT_M = 500


def secrets() -> dict:
    src = (REPO / "Shared" / "Secrets.swift").read_text()
    return dict(re.findall(r'let (\w+) = "([^"]+)"', src))


def fetch_json(url: str, headers: dict | None = None):
    # accessibility.cloud rejects urllib's default User-Agent.
    req = urllib.request.Request(url, headers={"User-Agent": "Hissi-seed-generator", **(headers or {})})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)


def region(place_info_id: str | None, station_name: str) -> str:
    """Berlin/Brandenburg from the AGS prefix of a legacy originalPlaceInfoId
    ("de:11000:…" = Berlin, "de:12xxx:…" = Brandenburg). BVG records carry the
    station name instead of an id — U-Bahn and "(Berlin)"/"Berlin"-named
    stations are Berlin either way."""
    if place_info_id:
        if place_info_id.startswith("de:11"):
            return "berlin"
        if place_info_id.startswith("de:12"):
            return "brandenburg"
    if ("(Berlin)" in station_name or station_name.startswith("Berlin")
            or re.match(r"^(U |S\+U)", station_name)):
        return "berlin"
    return "brandenburg"


def fetch_legacy_catalog(token: str) -> list[dict]:
    url = (f"{LEGACY_HOST}/equipment-infos.json"
           f"?appToken={token}&includeSourceIds={LEGACY_SOURCE_IDS}&limit=10000")
    data = fetch_json(url)
    records = []
    for feature in data["features"]:
        p = feature["properties"]
        if p.get("category") == "escalator":
            continue
        # A few records carry no geometry; keep them searchable anyway.
        lon, lat = (feature.get("geometry") or {}).get("coordinates") or (None, None)
        name = p.get("placeInfoName") or ""
        original_id = p.get("originalId") or ""
        record = {
            "id": p["_id"],
            "source": "accessibilityCloud",
            "acId": p["_id"],
            "stationName": name,
            "description": (p.get("shortDescription") or {}).get("de")
                or (p.get("description") or {}).get("de") or "",
            "latitude": lat,
            "longitude": lon,
            "sourceName": p.get("sourceName") or "",
            "organizationName": p.get("organizationName") or "",
            "region": region(p.get("originalPlaceInfoId"), name),
        }
        # A numeric originalId is the operator inventory number — the app's
        # match key against transit.accessibility.cloud records. (BVG-era
        # alphanumeric ids like "P1KBJ060" don't correspond to the transit
        # API's inventory ids; those records match nothing, which is fine —
        # their elevators are stop-place-linked upstream and need no backfill.)
        if original_id.isdigit():
            record["fastaEquipmentNumber"] = int(original_id)
        records.append(record)
    return records


def fetch_transit_pages(token: str, resource: str, select: str) -> list[dict]:
    docs: list[dict] = []
    page = 1
    while True:
        url = (f"{TRANSIT_HOST}/api/{resource}"
               f"?depth=0&draft=false&trash=false&limit={TRANSIT_PAGE_SIZE}&page={page}&{select}")
        data = fetch_json(url, {"Authorization": f"Bearer {token}"})
        docs.extend(data.get("docs", []))
        if not data.get("hasNextPage"):
            return docs
        page += 1


def fetch_transit_coverage(token: str) -> tuple[set[str], set[str]]:
    """(live inventory numbers, live VBB station numbers of stations that
    have at least one elevator)."""
    elevators = fetch_transit_pages(
        token, "elevators",
        "select%5Blinked_data%5D%5Boperator_inventory_id%5D=true&select%5Blocation%5D%5Bsite%5D=true",
    )
    stops = fetch_transit_pages(token, "stop-places", "select%5Bmain_identifier%5D=true")
    station_number = {
        s["id"]: (s.get("main_identifier") or "").rsplit(":", 1)[-1] for s in stops
    }
    inventory = set()
    covered_stations = set()
    for e in elevators:
        linked = e.get("linked_data") or {}
        if linked.get("operator_inventory_id"):
            inventory.add(str(linked["operator_inventory_id"]))
        site = (e.get("location") or {}).get("site")
        if site in station_number:
            covered_stations.add(station_number[site])
    return inventory, covered_stations


def station_key(name: str) -> str:
    """The app's station key (`EquipmentCatalog.stationKey`): case- and
    diacritic-folded, network prefix removed, so the seed's "U Spittelmarkt
    (Berlin)" and the live "Spittelmarkt (Berlin)" are one station."""
    folded = "".join(
        c for c in unicodedata.normalize("NFD", name) if not unicodedata.combining(c)
    ).lower().strip()
    for prefix in ("s+u ", "u ", "s "):
        if folded.startswith(prefix):
            return folded[len(prefix):].strip()
    return folded


def haversine_m(a: tuple, b: tuple) -> float:
    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)
    h = (math.sin((lat2 - lat1) / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2)
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


def clustered(group: list, limit: float) -> list[list]:
    """Single-linkage clusters: records within `limit` of each other are the
    same place. Biggest cluster first — it is usually the right one, but not
    always (U Leopoldplatz: two identical wrong records outvote the correct
    one), which is why this reports rather than picks."""
    remaining, out = list(group), []
    while remaining:
        cluster, grew = [remaining.pop(0)], True
        while grew:
            grew = False
            for r in list(remaining):
                point = (r["latitude"], r["longitude"])
                if any(haversine_m(point, (c["latitude"], c["longitude"])) <= limit
                       for c in cluster):
                    cluster.append(r)
                    remaining.remove(r)
                    grew = True
        out.append(cluster)
    return sorted(out, key=len, reverse=True)


def report_coordinate_outliers(records: list, limit: float = COORDINATE_SPREAD_LIMIT_M) -> None:
    """Flag stations whose records disagree about where the station is.

    The seed is the app's only source of coordinates, and since
    `EquipmentCatalog.stationBackfilled` a record's coordinate also answers
    for its unmatched siblings at the same station — so one wrong entry no
    longer misplaces just its own elevator. Known cases (2026-08-22):
    U Leopoldplatz (~5 km, 2 of 3 records) and Berlin Buckower Chaussee
    (~21 km, 2 of 4). Which cluster is right needs a human and a map; this
    only reports."""
    by_station = defaultdict(list)
    nameless = 0
    for r in records:
        key = station_key(r["stationName"])
        if not key:
            # No name means no search hit and no station backfill either —
            # the app keys both on it.
            nameless += 1
            continue
        if r.get("latitude") is not None and r.get("longitude") is not None:
            by_station[key].append(r)

    multi = sorted(((k, g) for k, g in by_station.items() if len(g) > 1),
                   key=lambda item: item[0])
    flagged = 0
    for key, group in multi:
        points = [(r["latitude"], r["longitude"]) for r in group]
        spread = max(haversine_m(a, b) for a in points for b in points)
        if spread <= limit:
            continue
        flagged += 1
        print(f"  coordinate spread {spread:.0f} m: {key}", file=sys.stderr)
        for cluster in clustered(group, limit):
            head = cluster[0]
            print(f"      {head['latitude']:.6f},{head['longitude']:.6f}  {len(cluster)}\u00d7 "
                  f"{head['stationName']} — {head['description'][:40]}", file=sys.stderr)
    suffix = " (see stderr)" if flagged else ""
    print(f"  {flagged} of {len(multi)} multi-elevator stations disagree "
          f"by more than {limit:.0f} m{suffix}")
    if nameless:
        print(f"  {nameless} records without a station name "
              f"(not searchable, and no station backfill for them)")


def main() -> None:
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUTPUT
    transit_token = os.environ.get("ACCESSIBILITY_CLOUD_APP_TOKEN") \
        or secrets().get("accessibilityCloudAppToken", "")
    legacy_token = os.environ.get("ACCESSIBILITY_CLOUD_LEGACY_TOKEN", "")
    if not legacy_token:
        sys.exit("ACCESSIBILITY_CLOUD_LEGACY_TOKEN is not set (legacy www.accessibility.cloud app token)")

    print("Fetching legacy accessibility.cloud catalog…")
    records = fetch_legacy_catalog(legacy_token)
    print(f"  {len(records)} elevators")

    print("Fetching transit.accessibility.cloud coverage…")
    inventory, covered_stations = fetch_transit_coverage(transit_token)
    print(f"  {len(inventory)} live inventory numbers, {len(covered_stations)} stations with elevators")

    bundled = json.loads(BUNDLED.read_text())["elevators"]

    # DB renumbers equipment while the legacy originalId stays frozen (e.g.
    # S Pankow-Heinersdorf: 10313414 retired, 10906243 current). The previous
    # seed generation resolved those via FaSta geo/track matching — keep its
    # number whenever the fresh originalId doesn't exist live but the
    # carried-over one does.
    bundled_numbers = {
        r["acId"]: r["fastaEquipmentNumber"]
        for r in bundled
        if r["source"] == "accessibilityCloud" and r.get("acId") and r.get("fastaEquipmentNumber")
    }
    renumbered = 0
    for r in records:
        if str(r.get("fastaEquipmentNumber")) in inventory:
            continue
        carried = bundled_numbers.get(r["acId"])
        if carried and str(carried) in inventory:
            r["fastaEquipmentNumber"] = carried
            renumbered += 1

    # Some legacy records carry no placeInfoName (e.g. Waßmannsdorf); the
    # previous generation borrowed those names (and their region) from FaSta —
    # carry them over, or the records become unfindable in name search.
    bundled_meta = {
        r["acId"]: r for r in bundled
        if r["source"] == "accessibilityCloud" and r.get("acId")
    }
    for r in records:
        carried = bundled_meta.get(r["acId"])
        if not r["stationName"] and carried and carried.get("stationName"):
            r["stationName"] = carried["stationName"]
            r["region"] = carried.get("region") or r["region"]

    numbered = [r for r in records if "fastaEquipmentNumber" in r]
    unmatched = [r for r in numbered if str(r["fastaEquipmentNumber"]) not in inventory]
    print(f"  {len(numbered)} records carry an inventory number, "
          f"{len(numbered) - len(unmatched)} match live records "
          f"({renumbered} via carried-over renumberings)")
    for r in unmatched:
        print(f"  no live match: {r['id']} {r['stationName']} — {r['description'][:50]}", file=sys.stderr)
    fasta = [r for r in bundled if r["source"] == "fasta"]
    brokenlifts_kept, brokenlifts_dropped = [], []
    for r in bundled:
        if r["source"] != "brokenlifts":
            continue
        (brokenlifts_dropped if r["brokenliftsStationId"] in covered_stations
         else brokenlifts_kept).append(r)
    print(f"Carried over {len(fasta)} fasta records; "
          f"{len(brokenlifts_kept)} brokenlifts gap records kept, "
          f"{len(brokenlifts_dropped)} dropped (station now live)")
    records += fasta + brokenlifts_kept

    print("Checking station coordinates…")
    report_coordinate_outliers(records)

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(
        {"generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "elevators": records},
        ensure_ascii=False, indent=1,
    ) + "\n")
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
