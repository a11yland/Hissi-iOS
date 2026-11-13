#!/usr/bin/env python3
"""Release notes for a version, taken from the in-app "Was ist neu" sheet.

The sheet is the curated changelog: `WhatsNewSheet.notes` in
Hissi/Views/WelcomeSheet.swift holds one `case "<version>":` per release with
notes, each a FeatureRow(title:, detail:) whose German literals are the keys
into Shared/Localizable.xcstrings. This prints them as Markdown, German first,
English below, so the GitHub release says what the app says.

A version missing from WelcomeGate.curatedVersions is a bugfix release (the
app stays silent); it gets a generic line instead of an error. Notes in the
sheet without the version in curatedVersions (or vice versa) are a mistake —
the sheet would never show — and fail loudly.

Usage: scripts/release-notes.py <version>   (e.g. 1.2.0)
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHEET = ROOT / "Hissi/Views/WelcomeSheet.swift"
GATE = ROOT / "Shared/WelcomeGate.swift"
CATALOG = ROOT / "Shared/Localizable.xcstrings"

SWIFT_STRING = r'"((?:[^"\\]|\\.)*)"'


def curated_versions() -> set[str]:
    match = re.search(r"curatedVersions: Set<String> = \[([^\]]*)\]", GATE.read_text())
    if not match:
        sys.exit("error: WelcomeGate.curatedVersions not found")
    return set(re.findall(SWIFT_STRING, match.group(1)))


def sheet_rows(version: str) -> list[tuple[str, str]]:
    """(title, detail) pairs of the version's case, in display order."""
    source = SHEET.read_text()
    start = source.find(f'case "{version}":')
    if start < 0:
        return []
    # The case runs until the next case or the default branch.
    end = re.compile(r'\n\s*(case "|default:)').search(source, start + 1)
    block = source[start:end.start() if end else len(source)]
    titles = re.findall(r"title:\s*" + SWIFT_STRING, block)
    details = re.findall(r"detail:\s*" + SWIFT_STRING, block)
    if len(titles) != len(details):
        sys.exit(f"error: {version}: {len(titles)} titles but {len(details)} details")
    return [(unescape(t), unescape(d)) for t, d in zip(titles, details)]


def unescape(literal: str) -> str:
    return literal.replace('\\"', '"').replace("\\\\", "\\")


def english(catalog: dict, key: str) -> str:
    try:
        return catalog["strings"][key]["localizations"]["en"]["stringUnit"]["value"]
    except KeyError:
        sys.exit(f'error: no English translation for "{key}" in Localizable.xcstrings')


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: release-notes.py <version>")
    version = sys.argv[1]

    curated = version in curated_versions()
    rows = sheet_rows(version)
    if curated and not rows:
        sys.exit(f"error: {version} is in WelcomeGate.curatedVersions but WhatsNewSheet has no notes for it")
    if rows and not curated:
        sys.exit(f"error: WhatsNewSheet has notes for {version}, but WelcomeGate.curatedVersions lacks it")

    if not rows:
        print("## Was ist neu\n\nFehlerbehebungen und kleinere Verbesserungen.\n")
        print("## What's new\n\nBug fixes and minor improvements.")
        return

    catalog = json.loads(CATALOG.read_text())
    print("## Was ist neu\n")
    for title, detail in rows:
        print(f"- **{title}**: {detail}")
    print("\n## What's new\n")
    for title, detail in rows:
        print(f"- **{english(catalog, title)}**: {english(catalog, detail)}")


if __name__ == "__main__":
    main()
