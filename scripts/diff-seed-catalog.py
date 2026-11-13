#!/usr/bin/env python3
"""Compare two seed catalogs and report drift (used by the Seed update workflow).

    python3 scripts/diff-seed-catalog.py <bundled.json> <fresh.json>

Prints a Markdown summary of added/removed/changed records and exits 1 when
the catalogs differ. Ignored: `generatedAt` (always differs) and coordinates
(source jitter would cause weekly noise; they don't affect matching or search).
The `stations` list (coordinates for stations the live data cannot place) is
compared by membership and name — a station dropping out means the platform
now carries a centroid for it.
The fields that matter are identity and mapping — `fastaEquipmentNumber` is
the app's metadata-backfill key against transit.accessibility.cloud, and a
dropped `brokenlifts` record means the platform now covers that station.
"""

import json
import sys
import traceback
from pathlib import Path

COMPARED_FIELDS = [
    "source", "stationName", "description", "sourceName", "organizationName",
    "fastaEquipmentNumber", "stationNumber", "brokenliftsStationId", "brokenliftsIndex",
    "region",
]


def load(path: str) -> tuple[dict[str, dict], dict[str, dict]]:
    file = json.loads(Path(path).read_text())
    return (
        {r["id"]: r for r in file["elevators"]},
        {s["stationId"]: s for s in file.get("stations", [])},
    )


def describe(record: dict) -> str:
    return f"`{record['id']}` — {record.get('stationName', '?')}: {record.get('description', '')}"


def main() -> int:
    (bundled, bundled_stations), (fresh, fresh_stations) = load(sys.argv[1]), load(sys.argv[2])
    stations_added = [fresh_stations[i] for i in sorted(fresh_stations.keys() - bundled_stations.keys())]
    stations_removed = [bundled_stations[i] for i in sorted(bundled_stations.keys() - fresh_stations.keys())]
    stations_renamed = [
        (bundled_stations[i], fresh_stations[i])
        for i in sorted(bundled_stations.keys() & fresh_stations.keys())
        if bundled_stations[i].get("name") != fresh_stations[i].get("name")
    ]

    added = [fresh[i] for i in sorted(fresh.keys() - bundled.keys())]
    removed = [bundled[i] for i in sorted(bundled.keys() - fresh.keys())]
    changed = []
    for rid in sorted(bundled.keys() & fresh.keys()):
        diffs = [
            f"{field}: `{bundled[rid].get(field)}` → `{fresh[rid].get(field)}`"
            for field in COMPARED_FIELDS
            if bundled[rid].get(field) != fresh[rid].get(field)
        ]
        if diffs:
            changed.append((bundled[rid], diffs))

    if not (added or removed or changed or stations_added or stations_removed or stations_renamed):
        print("No drift — bundled seed matches a fresh generation.")
        return 0

    print(f"## Seed drift: {len(added)} added, {len(removed)} removed, {len(changed)} changed, "
          f"{len(stations_added) + len(stations_removed) + len(stations_renamed)} station coordinates\n")
    for title, records in (("Added", added), ("Removed", removed)):
        if records:
            print(f"### {title} ({len(records)})\n")
            for r in records:
                print(f"- {describe(r)}")
            print()
    if changed:
        print(f"### Changed ({len(changed)})\n")
        for record, diffs in changed:
            print(f"- {describe(record)}")
            for d in diffs:
                print(f"  - {d}")
        print()
    for title, stations in (("Station coordinates added", stations_added), ("Station coordinates removed", stations_removed)):
        if stations:
            print(f"### {title} ({len(stations)})\n")
            for s in stations:
                print(f"- `{s['stationId']}` — {s.get('name', '?')}")
            print()
    if stations_renamed:
        print(f"### Station coordinates renamed ({len(stations_renamed)})\n")
        for old, new in stations_renamed:
            print(f"- `{old['stationId']}` — {old.get('name')} → {new.get('name')}")
        print()
    print("Regenerate before the next release: `python3 scripts/generate-seed-catalog.py`. "
          "Watch for `brokenliftsIndex` shifts — existing favorites keep their old "
          "index and would map to the wrong lift.")
    return 1


if __name__ == "__main__":
    # 0 = no drift, 1 = drift. Crashes exit 2 so the workflow can tell a
    # failed comparison apart from a drifted one.
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(2)
