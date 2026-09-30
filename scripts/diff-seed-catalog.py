#!/usr/bin/env python3
"""Compare two seed catalogs and report drift (used by the seed-drift workflow).

    python3 scripts/diff-seed-catalog.py <bundled.json> <fresh.json>

Prints a Markdown summary of added/removed/changed records and exits 1 when
the catalogs differ. Ignored: `generatedAt` (always differs) and coordinates
(source jitter would cause weekly noise; they don't affect matching or search).
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


def load(path: str) -> dict[str, dict]:
    records = json.loads(Path(path).read_text())["elevators"]
    return {r["id"]: r for r in records}


def describe(record: dict) -> str:
    return f"`{record['id']}` — {record.get('stationName', '?')}: {record.get('description', '')}"


def main() -> int:
    bundled, fresh = load(sys.argv[1]), load(sys.argv[2])

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

    if not (added or removed or changed):
        print("No drift — bundled seed matches a fresh generation.")
        return 0

    print(f"## Seed drift: {len(added)} added, {len(removed)} removed, {len(changed)} changed\n")
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
