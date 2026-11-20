#!/usr/bin/env python3
"""Generate the bundled national station list (Shared/Resources/national-stations.json).

transit.accessibility.cloud carries the DB InfraGO FaSta elevators nationwide,
but without a station: ~2500 records with an inventory number, a status and
mostly a centroid, and no name — invisible in Hissi, whose search matches the
station name. The Aufzugsstatus API (https://aufzuege.ploetzlich-querschnitt.de/api/,
plötzlich querschnitt, CC BY 4.0) knows the same elevators by the same FaSta
equipment number *with* their station. This list is the bridge: per DB
station its number, name, coordinate and the FaSta numbers of its elevators.
EquipmentCatalog.overlaid names the nameless accessibility.cloud records from
it, so DB stations across Germany are searchable offline, favoritable under
their numeric accessibility.cloud id and refreshed in the one favorites batch
— the Aufzugsstatus API itself is then only asked for the city operators
(HVV, KVB, MVG, VAG) and for DB stations this list doesn't know yet.

The API has no station list endpoint, so the run crawls in two stages:

1. `/stations/near` over a grid of Germany (radius covering each cell, limit
   100; a full page splits the cell in four) — the DB stations are the ones
   with a `station_number`; KVB's and the Swiss/Austrian OSM stations have
   none and are skipped.
2. `/lifts?station_number=N` per station for the FaSta numbers (source
   `fasta` only). ~1300 stations, ~1450 requests in all.

Paced to one request per second — the fair-use limit is 60/min per IP — with
a descriptive User-Agent and one retry after a 429's Retry-After, so a run
takes ~25 minutes. Output is deterministic (sorted, rounded) apart from
`generatedAt`; `--diff OLD NEW` compares two files ignoring that date and
exits 1 on drift, for the update workflow.

    python3 scripts/generate-national-stations.py [output-path]
    python3 scripts/generate-national-stations.py --diff old.json new.json
"""

import json
import math
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date

BASE = "https://aufzuege.ploetzlich-querschnitt.de"
USER_AGENT = "Hissi-seed-generator/1.0 (hissi.app)"
PACE_SECONDS = 1.0
# Germany, generously: the grid's edge cells reach into the neighbours, whose
# stations drop out for lack of a DB station number.
LAT0, LAT1, LON0, LON1 = 47.2, 55.1, 5.8, 15.1
CELL_LAT, CELL_LON = 0.7, 1.0
DEFAULT_OUTPUT = "Shared/Resources/national-stations.json"

calls = 0


def get(path, query):
    global calls
    url = f"{BASE}/{path}?{urllib.parse.urlencode(query)}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    for attempt in range(3):
        calls += 1
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                data = json.load(response)
            time.sleep(PACE_SECONDS)
            return data
        except urllib.error.HTTPError as error:
            if error.code == 429 and attempt < 2:
                wait = float(error.headers.get("Retry-After") or 5) or 5
                print(f"429 on {path}, waiting {wait:.0f} s", file=sys.stderr)
                time.sleep(min(wait, 30))
                continue
            raise
    raise RuntimeError(f"gave up on {url}")


def is_placeholder(name):
    return name.startswith("Bahnhof ") and name[8:].isdigit()


def crawl_stations():
    """Stage 1: every station the API places that carries a DB station number."""
    found = {}  # station_number -> name

    def cell(lat, lon, half_lat, half_lon):
        radius = math.hypot(half_lat * 111.0, half_lon * 111.0 * math.cos(math.radians(lat))) * 1.05
        result = get("stations/near", {"lat": round(lat, 4), "lon": round(lon, 4),
                                       "radius_km": min(round(radius, 2), 200), "limit": 100})
        if len(result) >= 100 and half_lat > 0.02:
            for d_lat in (-half_lat / 2, half_lat / 2):
                for d_lon in (-half_lon / 2, half_lon / 2):
                    cell(lat + d_lat, lon + d_lon, half_lat / 2, half_lon / 2)
            return
        for station in result:
            number = station.get("station_number")
            if number is None or is_placeholder(station["name"]):
                continue
            found.setdefault(number, station["name"])

    lat = LAT0 + CELL_LAT / 2
    while lat < LAT1:
        lon = LON0 + CELL_LON / 2
        while lon < LON1:
            cell(lat, lon, CELL_LAT / 2, CELL_LON / 2)
            lon += CELL_LON
        lat += CELL_LAT
    return found


def crawl_lifts(station_numbers):
    """Stage 2: the FaSta elevators per station — number, name and coordinate come from them."""
    stations = []
    for index, number in enumerate(sorted(station_numbers), 1):
        lifts = get("lifts", {"station_number": number, "limit": 200})
        fasta = [lift for lift in lifts
                 if lift.get("source") == "fasta" and lift.get("station_name") and str(lift.get("source_id", "")).isdigit()]
        if not fasta:
            continue
        # The name the lifts carry (the stations endpoint may list a placeholder too).
        names = sorted({lift["station_name"].strip() for lift in fasta})
        placed = [lift for lift in fasta if lift.get("lat") is not None and lift.get("lon") is not None]
        entry = {
            "stationNumber": number,
            "name": names[0],
            "lifts": sorted({int(lift["source_id"]) for lift in fasta}),
        }
        if placed:
            entry["latitude"] = round(sum(lift["lat"] for lift in placed) / len(placed), 5)
            entry["longitude"] = round(sum(lift["lon"] for lift in placed) / len(placed), 5)
        stations.append(entry)
        if index % 100 == 0:
            print(f"{index}/{len(station_numbers)} stations, {calls} requests", file=sys.stderr)
    return stations


def generate(output_path):
    numbers = crawl_stations()
    print(f"stage 1: {len(numbers)} DB stations placed, {calls} requests", file=sys.stderr)
    stations = crawl_lifts(numbers.keys())
    lift_count = sum(len(station["lifts"]) for station in stations)
    print(f"stage 2: {len(stations)} stations, {lift_count} elevators, {calls} requests in all", file=sys.stderr)
    document = {
        "generatedAt": date.today().isoformat(),
        "source": "Aufzugsstatus API, https://aufzuege.ploetzlich-querschnitt.de/api/ (plötzlich querschnitt, CC BY 4.0)",
        "stations": stations,
    }
    with open(output_path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, ensure_ascii=False, indent=1)
        handle.write("\n")


def diff(old_path, new_path):
    """Exit 1 on drift (stations or elevators), 0 when only generatedAt differs."""
    def index(path):
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        return {station["stationNumber"]: station for station in data.get("stations", [])}

    old, new = index(old_path), index(new_path)
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    changed = sorted(n for n in set(old) & set(new)
                     if old[n]["lifts"] != new[n]["lifts"] or old[n]["name"] != new[n]["name"])
    coordinate_only = sorted(n for n in set(old) & set(new) if n not in changed and old[n] != new[n])
    print(f"## National stations: {len(old)} → {len(new)}")
    print()
    for label, numbers, source in (("Added", added, new), ("Removed", removed, old), ("Changed", changed, new)):
        if numbers:
            print(f"**{label} ({len(numbers)}):** " + ", ".join(f"{source[n]['name']} ({n})" for n in numbers[:40])
                  + (" …" if len(numbers) > 40 else ""))
            print()
    if coordinate_only:
        print(f"Coordinate-only changes at {len(coordinate_only)} stations (no drift on their own).")
    return 1 if (added or removed or changed) else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--diff"]:
        sys.exit(diff(args[1], args[2]))
    generate(args[0] if args else DEFAULT_OUTPUT)
