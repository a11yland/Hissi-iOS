#!/usr/bin/env python3
"""Generate the bundled seed catalog (format version 2).

Every seed record is a live elevator under its live id, so a favorite created
from the seed (first launch, offline search) is a live favorite from the
start. Two sources supply elevators: transit.accessibility.cloud (numeric
ids) and the VRR infrastructure API (ids `vrr:<resourceId>`; the apps derive
the source from the id, ElevatorSource). The seed backfills what the app's depth=0 list fetch doesn't carry —
station, region and transport modes for elevators the platform hasn't linked
to a stop place, source and operator names, station coordinates — and
carries the search when there is no network.

Sources:

- **transit.accessibility.cloud** (Bearer `trtok_…`): elevators (description,
  inventory number, centroid, feed, operator), stop places (name, DHID,
  transport modes). Upstream links only the Berlin/Brandenburg elevators to a
  stop place (610 of 3238 on 2026-11-21); the DB elevators everywhere else
  carry a centroid and a description, but no station.
- **VBB GTFS** (public, ~80 MB): coordinates of the platform's stop places,
  keyed by DHID (`stop_id` = the stop place's `main_identifier`). They place
  unlinked elevators in Berlin/Brandenburg at a stop place and stand in for
  linked elevators without a centroid.
- **gtfs.de** regional and long-distance GTFS (public, CC BY 4.0, data by
  DELFI e.V.): the rail stations of all of Germany. An unlinked elevator no
  stop place claims is assigned to the nearest of them within
  ASSIGN_RADIUS_M — what makes the nationwide DB elevators searchable.
- **Federal state borders** (BKG VG250 via its WFS, © GeoBasis-DE / BKG,
  Datenlizenz Deutschland – Namensnennung 2.0): the region of a gtfs.de
  station, which has no DHID to read it from. Only the state's name reaches
  the seed.
- **VRR infrastructure API** (MIP, https://www.opendata-oepnv.de/ht/de/api,
  CC BY 4.0, public API key from that page): the elevators of the municipal
  networks in Nordrhein-Westfalen (Stadtbahn, U-Bahn, Schwebebahn — ~275 at
  ~146 stops on 2026-11-24) that transit.accessibility.cloud doesn't carry,
  with their stops (DHID, name, coordinate). Escalators and ramps are left
  out. The apps fetch the status from the same endpoint; only identity and
  place reach the seed. `VRR_API_KEY` overrides the key. Unlike the other
  sources, a failed or implausibly short VRR answer does not fail the run:
  the bundled seed's VRR records are carried over instead.

Station names and coordinates in the seed come from DELFI e.V. (via
gtfs.de, CC BY 4.0) and VBB Verkehrsverbund Berlin-Brandenburg GmbH (CC BY),
the NRW elevators and their stops from VRR (Verkehrsverbund Rhein-Ruhr AöR,
CC BY 4.0) — both apps name them in their about screens.

Downloads are cached for a week in the temp directory; `VBB_GTFS_ZIP`,
`GTFS_DE_RV_ZIP`, `GTFS_DE_FV_ZIP` and `STATES_GEOJSON` point at local copies
instead. A failed download fails the run.

    ACCESSIBILITY_CLOUD_APP_TOKEN=trtok_… \\
    python3 scripts/generate-seed-catalog.py [output-path]

The token falls back to `accessibilityCloudAppToken` in Shared/Secrets.swift.

`legacyIds` maps the ids of the format-1 seed (legacy accessibility.cloud
`_id`, `fasta-…`, `brokenlifts-…`) onto live ids, so a favorite created from
an old seed preview keeps resolving. It is computed once from a format-1
bundled seed (via the operator inventory number) and carried over afterwards
for as long as its target stays live.
"""

import csv
import io
import json
import math
import os
import re
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO / "Shared" / "Resources" / "seed-catalog.json"
BUNDLED = DEFAULT_OUTPUT  # carry-over source for legacyIds

FORMAT_VERSION = 2

TRANSIT_HOST = "https://transit.accessibility.cloud"

# The VRR infrastructure API ("MIP"). The key is printed on
# https://www.opendata-oepnv.de/ht/de/api — public, not a secret.
VRR_INFRASTRUCTURE_URL = "https://mip.vrr.de/vrr-api/rest/stop/all/infrastructure"
VRR_PUBLIC_API_KEY = "F3E46748D2DED"
VRR_ID_PREFIX = "vrr:"
VRR_SOURCE_NAME = "VRR"
TRANSIT_PAGE_SIZE = 1000

# The `feeds` collection is closed to app tokens (403), so the elevators
# carry only the feed id. A feed missing here is reported and gets no source
# name until it is added.
FEED_NAMES = {
    7: "DB FaSta",
    21: "BVG",
}

CACHE_DIR = Path(tempfile.gettempdir())
CACHE_SECONDS = 7 * 86_400
DOWNLOADS = {
    "VBB_GTFS_ZIP": ("https://www.vbb.de/fileadmin/user_upload/VBB/Dokumente/API-Datensaetze/gtfs-mastscharf/GTFS.zip",
                     "hissi-vbb-gtfs.zip"),
    "GTFS_DE_RV_ZIP": ("https://download.gtfs.de/germany/rv_free/latest.zip", "hissi-gtfs-de-rv.zip"),
    "GTFS_DE_FV_ZIP": ("https://download.gtfs.de/germany/fv_free/latest.zip", "hissi-gtfs-de-fv.zip"),
    "STATES_GEOJSON": ("https://sgx.geodatenzentrum.de/wfs_vg250?SERVICE=WFS&VERSION=2.0.0&REQUEST=GetFeature"
                       "&TYPENAMES=vg250:vg250_lan&SRSNAME=EPSG:4326&OUTPUTFORMAT=application/json",
                       "hissi-vg250-states.geo.json"),
}

# An elevator further than this from every station belongs to none of them —
# measured 2026-11-21: 2519 of 2528 unlinked DB elevators lie within 300 m of
# a gtfs.de station, the other nine are 900 m to 5 km off (wrong centroids
# upstream, e.g. "S Bellevue → Gleis 1" in the middle of the Tiergarten).
ASSIGN_RADIUS_M = 300

# Format-1 seed ids whose upstream description was reworded beyond the
# automatic station + description match — checked by hand on 2026-11-21:
# same station, levels, line/track and direction; where the old seed listed
# one elevator twice (legacy record plus "fasta-…" record, or two legacy
# records), the station's elevator count settles it (counts from db.info and
# brokenlifts.org). A wrong entry would show another elevator's status, so
# doubtful cases stay out. Applied on top of the computed and carried-over
# map while the target is live.
LEGACY_OVERRIDES = {
    "2aZ6Z3TXpWp9CGLT6": "6963",  # Frankfurt (Oder), Gleis 9/10 ↔ Unterführung
    "6fEWS8wAASYfTF38N": "6700",  # Berlin Hauptbahnhof, Zugang ↔ 1. UG ↔ U5
    "xnCYoH2X4wJn8N9Zp": "6701",  # U Frankfurter Tor, Zwischenebene ↔ U-Bahnsteig
    "6CeP3C8yr2SFGDTPS": "6830",  # Zoologischer Garten, Straße ↔ Zwischenebene und U2 (→ Ruhleben)
    "ddaNEBZFZ3xQN6QCD": "6837",  # U Olympia-Stadion, Straße ↔ U2 (→ Ruhleben)
    "23ZEJX7dztP3iQnYN": "6852",  # U Olympia-Stadion, Straße ↔ U2 (→ Pankow)
    "wA4TuQrGok23HxFbQ": "6256",  # S+U Brandenburger Tor, Zwischenebene ↔ Gleis 1/2 (S-Bahn)
    "38aodZ8v99ZHZRkY5": "6703",  # S+U Brandenburger Tor, Straße ↔ Zwischenebene (→ S-Bahn) ↔ U5
    "rhtokrPXQjeWShxDc": "5113",  # S Babelsberg, the station's only elevator (db.info)
    "MRajamnoFGejZvFfF": "6780",  # S+U Friedrichstraße, Bahnhofshalle ↔ Straße ↔ Zwischenebene (→ U6)
    # Word-for-word duplicates of an old record already mapped to the same
    # elevator — the old seed listed these lifts twice.
    "d7DKETxKR53B6Xzy8": "7266",  # U Wilmersdorfer Str., the station's only elevator
    "M4sQuZbPYFr6ms7GC": "6705",  # S+U Neukölln, S-Bahn ↔ Straße ↔ U7 (duplicate of MxCbffn7wZ8M55X75)
    "M66T7FLqXHtbKsLYN": "6964",  # U Berliner Str., Zwischenebene ↔ U9 (duplicate of EnztxYzqf8eGJZ2hu)
}
# S Fredersdorf has no elevator at all (db.info, 2026-11-21) — its three
# old brokenlifts.org records were stale and map to nothing.

# Region raw values, shared with TransitRegion in both apps.
REGION_BY_AGS = {
    "01": "schleswig-holstein", "02": "hamburg", "03": "niedersachsen", "04": "bremen",
    "05": "nordrhein-westfalen", "06": "hessen", "07": "rheinland-pfalz",
    "08": "baden-wuerttemberg", "09": "bayern", "10": "saarland", "11": "berlin",
    "12": "brandenburg", "13": "mecklenburg-vorpommern", "14": "sachsen",
    "15": "sachsen-anhalt", "16": "thueringen",
}


# MARK: - HTTP

def secrets() -> dict:
    path = REPO / "Shared" / "Secrets.swift"
    if not path.exists():
        return {}
    return dict(re.findall(r'let (\w+) = "([^"]+)"', path.read_text()))


def fetch_json(url: str, token: str):
    # accessibility.cloud rejects urllib's default User-Agent.
    req = urllib.request.Request(url, headers={
        "User-Agent": "Hissi-seed-generator",
        "Authorization": f"Bearer {token}",
    })
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as error:
            # A rejected token is the usual failure (expired, or pasted with
            # quotes) — name it instead of a stack trace.
            if error.code in (401, 403):
                sys.exit(f"error: {TRANSIT_HOST} rejected ACCESSIBILITY_CLOUD_APP_TOKEN "
                         f"(HTTP {error.code}) — the token is invalid or expired")
            if attempt == 2 or error.code < 500:
                raise
        except (urllib.error.URLError, TimeoutError):
            if attempt == 2:
                raise
        time.sleep(5 * (attempt + 1))


def select(*paths: str) -> str:
    return "&".join(
        "select" + "".join(f"%5B{part}%5D" for part in path.split(".")) + "=true"
        for path in paths
    )


def fetch_transit_pages(token: str, resource: str, query: str, depth: int = 0) -> list[dict]:
    docs: list[dict] = []
    page = 1
    while True:
        url = (f"{TRANSIT_HOST}/api/{resource}?depth={depth}&draft=false&trash=false"
               f"&locale=de&fallback-locale=de&limit={TRANSIT_PAGE_SIZE}&page={page}&{query}")
        data = fetch_json(url, token)
        docs.extend(data.get("docs", []))
        if not data.get("hasNextPage"):
            return docs
        page += 1


def cached_download(env: str) -> Path:
    override = os.environ.get(env)
    if override:
        return Path(override)
    url, name = DOWNLOADS[env]
    cache = CACHE_DIR / name
    if cache.exists() and time.time() - cache.stat().st_mtime < CACHE_SECONDS:
        return cache
    print(f"  downloading {url}")
    # vbb.de sits behind Cloudflare, which answers urllib's default
    # User-Agent with 403.
    req = urllib.request.Request(url, headers={"User-Agent": "Hissi-seed-generator"})
    with urllib.request.urlopen(req, timeout=600) as response:
        cache.write_bytes(response.read())
    return cache


# MARK: - transit.accessibility.cloud

def fetch_elevators(token: str) -> list[dict]:
    # depth=1 only to resolve the operator's name; the stop place relation is
    # trimmed to its id by populate, so the response stays flat otherwise.
    query = "&".join([
        select("function.short_visual", "internal_description", "location.site",
               "location.centroid", "linked_data.operator_inventory_id",
               "linked_data.operator_org", "feed", "elevator_type"),
        "populate%5Bstop-places%5D%5Bid%5D=true",
        "populate%5Borganizations%5D%5Bname%5D=true",
    ])
    return fetch_transit_pages(token, "elevators", query, depth=1)


def fetch_stop_places(token: str) -> list[dict]:
    return fetch_transit_pages(
        token, "stop-places",
        select("normalized_name", "main_identifier", "modes.servicedTransportModes"),
    )


def relation_id(value):
    if isinstance(value, dict):
        value = value.get("id")
    return value


def text(value) -> str:
    if isinstance(value, dict):
        value = value.get("de") or next((v for v in value.values() if v), None)
    return (value or "").strip() if isinstance(value, str) else ""


def centroid(elevator: dict) -> tuple[float, float] | None:
    point = (elevator.get("location") or {}).get("centroid")
    if isinstance(point, list) and len(point) == 2 and all(isinstance(v, (int, float)) for v in point):
        return (point[1], point[0])  # [longitude, latitude] upstream
    return None


def region_of_dhid(dhid: str) -> str | None:
    match = re.match(r"de:(\d\d)", dhid or "")
    return REGION_BY_AGS.get(match.group(1)) if match else None


def station_number(dhid: str) -> str:
    return (dhid or "").rsplit(":", 1)[-1]


# MARK: - GTFS

def vbb_coordinates(dhids: set[str]) -> dict[str, tuple[float, float]]:
    """DHID → (latitude, longitude) from the VBB GTFS stops: the parent
    station row (location_type 1) when there is one, else the mean of the
    station's platforms (`parent_station`, or a `<dhid>::n` id)."""
    parents: dict[str, tuple[float, float]] = {}
    children: dict[str, list[tuple[float, float]]] = defaultdict(list)
    with zipfile.ZipFile(cached_download("VBB_GTFS_ZIP")) as archive, archive.open("stops.txt") as stops:
        for row in csv.DictReader(io.TextIOWrapper(stops, encoding="utf-8-sig")):
            try:
                point = (float(row["stop_lat"]), float(row["stop_lon"]))
            except (KeyError, ValueError):
                continue
            stop_id = row["stop_id"]
            if stop_id in dhids and row.get("location_type") == "1":
                parents[stop_id] = point
                continue
            parent = row.get("parent_station") or stop_id.split("::", 1)[0]
            if parent in dhids:
                children[parent].append(point)
    found = dict(parents)
    for dhid, points in children.items():
        found.setdefault(dhid, mean(points))
    return found


def mean(points: list[tuple[float, float]]) -> tuple[float, float]:
    return (sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points))


def gtfs_de_stations() -> list[dict]:
    """The rail stations of Germany from gtfs.de's regional and long-distance
    feeds: one per parent station (or per lone stop), at its own coordinate
    or the mean of its platforms. gtfs.de's stop ids are hashes that change
    between releases, so a station is identified by its name."""
    groups: dict[str, dict] = {}
    for env in ("GTFS_DE_RV_ZIP", "GTFS_DE_FV_ZIP"):
        with zipfile.ZipFile(cached_download(env)) as archive, archive.open("stops.txt") as stops:
            for row in csv.DictReader(io.TextIOWrapper(stops, encoding="utf-8-sig")):
                try:
                    point = (float(row["stop_lat"]), float(row["stop_lon"]))
                except (KeyError, ValueError):
                    continue
                key = row.get("parent_station") or row["stop_id"]
                group = groups.setdefault(key, {"parent": None, "points": [], "names": []})
                if row.get("location_type") == "1" or not row.get("parent_station"):
                    group["parent"] = (row["stop_name"], point)
                else:
                    group["points"].append(point)
                    group["names"].append(row["stop_name"])
    stations = []
    for group in groups.values():
        name, point = group["parent"] or (None, None)
        if point is None:
            point = mean(group["points"])
        stations.append({"name": station_display_name(name, group["names"]), "point": point})
    return [s for s in stations if s["name"]]


def station_display_name(parent: str | None, children: list[str]) -> str:
    """The platforms' name, the parent's only for a lone stop. The platforms
    carry the DB station name ("Lippstadt", "München Marienplatz"); the
    parent is DELFI's area name, which is often a bus interchange or a
    single platform ("Lippstadt, Bustreff Bahnhof", "Marienplatz",
    "Bad Kleinen Gl. 1"). Several parents whose platforms share a name
    become one station — stations are keyed by name."""
    if children:
        name = Counter(c.strip() for c in children).most_common(1)[0][0]
    else:
        name = (parent or "").strip()
    # Some platforms name their track too ("Magdeburg Gl. 4",
    # "Hofgeismar Gl.1 Ri. Hümme").
    return TRACK_SUFFIX.sub("", name).strip() or name


TRACK_SUFFIX = re.compile(
    r"[\s,]+(Bereich\s+)?(Gl\.?|Gleis)\s*\d+\w*(\s*[+/]\s*\d+\w*)*(\s+Ri\..*)?$")


# MARK: - Geometry

def haversine_m(a: tuple, b: tuple) -> float:
    lat1, lon1 = map(math.radians, a)
    lat2, lon2 = map(math.radians, b)
    h = (math.sin((lat2 - lat1) / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2)
    return 2 * 6_371_000 * math.asin(math.sqrt(h))


class NearestIndex:
    """Grid lookup for the nearest station within ASSIGN_RADIUS_M; cells are
    ~1 km, so the 3×3 neighbourhood covers the radius everywhere in Germany."""

    def __init__(self, stations: list[dict]):
        self.cells: dict[tuple[int, int], list[dict]] = defaultdict(list)
        for station in stations:
            self.cells[self.cell(station["point"])].append(station)

    @staticmethod
    def cell(point: tuple[float, float]) -> tuple[int, int]:
        return (math.floor(point[0] * 100), math.floor(point[1] * 60))

    def nearest(self, point: tuple[float, float], radius: float = ASSIGN_RADIUS_M):
        row, col = self.cell(point)
        best, best_distance = None, radius
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                for station in self.cells.get((row + dr, col + dc), []):
                    distance = haversine_m(point, station["point"])
                    if distance <= best_distance:
                        best, best_distance = station, distance
        return best, best_distance


class StateLookup:
    """Federal state of a coordinate (point in polygon, ray casting) over the
    BKG VG250 states. Only the land areas (`gf` 4) count — the coastal
    waters (`gf` 2/3) would put a harbour station in the sea's state."""

    def __init__(self, path: Path):
        self.states = []
        for feature in json.loads(path.read_text())["features"]:
            properties = feature["properties"]
            if properties.get("gf") != 4:
                continue
            region = REGION_BY_AGS.get(properties.get("ags"))
            geometry = feature["geometry"]
            polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
            for polygon in polygons:
                ring = polygon[0]
                lons = [p[0] for p in ring]
                lats = [p[1] for p in ring]
                self.states.append((region, (min(lats), max(lats), min(lons), max(lons)), polygon))

    def region(self, point: tuple[float, float]) -> str | None:
        lat, lon = point
        for region, (lat0, lat1, lon0, lon1), polygon in self.states:
            if lat0 <= lat <= lat1 and lon0 <= lon <= lon1 and self.inside(lon, lat, polygon):
                return region
        # Outside every border: DB stations abroad (Basel Bad Bf) or on a
        # shore the simplified outline cuts off (Überlingen) — the state
        # whose border runs closest.
        return min(
            ((haversine_m(point, (p[1], p[0])), region)
             for region, _, polygon in self.states for p in polygon[0]),
            default=(0, None),
        )[1]

    @staticmethod
    def inside(x: float, y: float, polygon: list) -> bool:
        def in_ring(ring) -> bool:
            inside = False
            j = len(ring) - 1
            for i in range(len(ring)):
                xi, yi = ring[i][0], ring[i][1]
                xj, yj = ring[j][0], ring[j][1]
                if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
                    inside = not inside
                j = i
            return inside
        return in_ring(polygon[0]) and not any(in_ring(hole) for hole in polygon[1:])


# MARK: - VRR

def seed_sort_key(elevator_id: str) -> tuple:
    """Numeric (transit.accessibility.cloud) ids first, in numeric order;
    other sources after them, by id."""
    return (0, int(elevator_id), "") if elevator_id.isdigit() else (1, 0, elevator_id)


def fetch_vrr() -> list[dict] | None:
    """All VRR stops with their infrastructure; None when the API fails —
    the caller then keeps what the bundled seed has."""
    key = (os.environ.get("VRR_API_KEY") or VRR_PUBLIC_API_KEY).strip()
    req = urllib.request.Request(VRR_INFRASTRUCTURE_URL, headers={
        "User-Agent": "Hissi-seed-generator",
        "x-api-key": key,
    })
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = json.load(resp)
            return data if isinstance(data, list) else None
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            print(f"  VRR request failed ({error})", file=sys.stderr)
            if isinstance(error, urllib.error.HTTPError) and error.code < 500:
                return None
        time.sleep(5 * (attempt + 1))
    return None


def vrr_station_name(name: str, place: str) -> str:
    """The stop's name with its town spelled out. The feed is not uniform:
    most names start with the town ("Duisburg Duissern U-Bf"), some
    abbreviate it ("D-Kirchplatz U", "GE Heinrich-König-Platz"), a few carry
    none ("St. Anna Krankenhaus")."""
    name = " ".join((name or "").split())
    place = " ".join((place or "").split())
    if not place:
        return name
    if name.startswith(place):
        # "Bielefeld, Nordpark" → "Bielefeld Nordpark"
        return " ".join((place + " " + name[len(place):].lstrip(" ,")).split())
    abbreviation = re.match(r"([A-ZÄÖÜ]{1,3})[- ]", name)
    if abbreviation and fold_station(place).startswith(fold_station(abbreviation.group(1))):
        return f"{place} {name[abbreviation.end():].lstrip()}"
    return f"{place} {name}"


def fold_station(name: str) -> str:
    """Station names compared loosely: case, diacritics, punctuation and the
    Hbf/Hauptbahnhof, Bf/Bahnhof spellings folded away."""
    folded = "".join(c for c in unicodedata.normalize("NFD", name) if not unicodedata.combining(c)).lower()
    folded = folded.replace("ß", "ss").replace("hauptbahnhof", "hbf")
    folded = re.sub(r"\b(bahnhof|bhf|bf)\b", "", folded)
    return re.sub(r"[^a-z0-9]", "", folded)


def vrr_records(stops: list[dict], known_stations: list[dict]) -> tuple[list[dict], list[dict]]:
    """Seed records and stations for the VRR elevators. `known_stations` are
    the stations already in this generation: a VRR stop standing at one of
    them under the same (folded) name takes its spelling, so the apps — which
    group by station name — show one station ("Wuppertal Hbf": DB's lifts and
    the Schwebebahn's)."""
    records: dict[str, dict] = {}
    stations: dict[str, dict] = {}
    adopted = misplaced = 0
    for stop in stops:
        dhid = (stop.get("ifopt") or "").strip()
        lifts = [i for i in stop.get("infrastructure") or []
                 if i.get("type") == "Aufzug" and (i.get("resourceId") or "").strip()]
        if not dhid or not lifts or stop.get("latitude") is None or stop.get("longitude") is None:
            continue
        stop_point = (stop["latitude"], stop["longitude"])
        name = vrr_station_name(stop.get("name"), stop.get("place"))
        for known in known_stations:
            if (fold_station(known["name"]) == fold_station(name)
                    and haversine_m(stop_point, (known["latitude"], known["longitude"])) <= ASSIGN_RADIUS_M):
                if known["name"] != name:
                    print(f"    {name} → {known['name']} (existing station)", file=sys.stderr)
                name = known["name"]
                adopted += 1
                break
        region = region_of_dhid(dhid)
        if region is None:
            print(f"  VRR stop without region: {dhid} {name}", file=sys.stderr)
        station = {"stationId": dhid, "dhid": dhid, "name": name, "region": region,
                   "latitude": round(stop_point[0], 6), "longitude": round(stop_point[1], 6)}
        stations[dhid] = {k: v for k, v in station.items() if v is not None}
        for lift in lifts:
            # The area label ("Allgemeiner Bereich", "SWB_O") says nothing;
            # the description is what tells two lifts apart.
            description = " ".join((lift.get("description") or "").split())
            # The lift's own coordinate — unless it is missing or plainly
            # wrong (the feed places some lifts kilometres away, a few in
            # the Norwegian Sea): then the stop's.
            point = stop_point
            if lift.get("latitude") is not None and lift.get("longitude") is not None:
                own = (lift["latitude"], lift["longitude"])
                if haversine_m(own, stop_point) <= ASSIGN_RADIUS_M:
                    point = own
                else:
                    misplaced += 1
            record = {
                "id": VRR_ID_PREFIX + lift["resourceId"].strip(),
                "stationId": dhid,
                "stationName": name,
                "stationModes": [],
                "region": region,
                "description": description,
                "latitude": round(point[0], 6),
                "longitude": round(point[1], 6),
                "sourceName": VRR_SOURCE_NAME,
                "organizationName": "",
            }
            record = {k: v for k, v in record.items() if v is not None}
            # The feed lists a lift twice now and then — the fuller
            # description wins.
            previous = records.get(record["id"])
            if previous is None or len(description) > len(previous["description"]):
                records[record["id"]] = record
    print(f"  {len(records)} VRR elevators at {len(stations)} stops, "
          f"{adopted} stops under an existing station's name, "
          f"{misplaced} lift coordinates further than {ASSIGN_RADIUS_M} m from their stop replaced by the stop's")
    return list(records.values()), [stations[k] for k in sorted(stations)]


def vrr_block(bundled: dict | None, known_stations: list[dict]) -> tuple[list[dict], list[dict]]:
    """The VRR part of the seed — fresh, or carried over from the bundled
    seed when the API fails or answers with less than half of what the seed
    knows (an outage must not turn into a pull request deleting NRW)."""
    carried = [r for r in (bundled or {}).get("elevators", []) if r["id"].startswith(VRR_ID_PREFIX)]
    carried_ids = {r["stationId"] for r in carried}
    carried_stations = [s for s in (bundled or {}).get("stations", []) if s["stationId"] in carried_ids]
    print("Fetching the VRR infrastructure API…")
    stops = fetch_vrr()
    if stops is not None:
        records, stations = vrr_records(stops, known_stations)
        if len(records) * 2 >= len(carried):
            return records, stations
        print(f"  warning: VRR answered with {len(records)} elevators, the bundled seed has "
              f"{len(carried)} — keeping the bundled ones", file=sys.stderr)
    else:
        print(f"  warning: VRR unavailable — keeping the bundled seed's {len(carried)} VRR elevators",
              file=sys.stderr)
    return carried, carried_stations


# MARK: - Build

def build(token: str, bundled: dict | None) -> dict:
    print("Fetching transit.accessibility.cloud…")
    elevators = fetch_elevators(token)
    stops = fetch_stop_places(token)
    # The collection also carries escalators and moving walkways (none so
    # far, the field is unset everywhere) — the app tracks elevators only.
    elevators = [e for e in elevators if e.get("elevator_type") in (None, "elevator")]
    print(f"  {len(elevators)} elevators, {len(stops)} stop places")

    print("Placing the stop places (VBB GTFS)…")
    stops_by_id = {s["id"]: s for s in stops if s.get("main_identifier") and text(s.get("normalized_name"))}
    stop_points = vbb_coordinates({s["main_identifier"] for s in stops_by_id.values()})
    print(f"  {len(stop_points)} of {len(stops_by_id)} stop places with a coordinate")

    stations: dict[str, dict] = {}

    def transit_station(stop: dict) -> dict:
        dhid = stop["main_identifier"]
        sid = station_number(dhid)
        if sid not in stations:
            stations[sid] = {
                "stationId": sid,
                "dhid": dhid,
                "name": text(stop.get("normalized_name")),
                "region": region_of_dhid(dhid),
                "modes": sorted(int(m) for m in ((stop.get("modes") or {}).get("servicedTransportModes") or [])
                                if str(m).isdigit()),
                "point": stop_points.get(dhid),
            }
        return stations[sid]

    transit_index = NearestIndex([
        {"stop": stop, "point": stop_points[stop["main_identifier"]]}
        for stop in stops_by_id.values() if stop["main_identifier"] in stop_points
    ])

    print("Loading the rail stations of Germany (gtfs.de)…")
    states = StateLookup(cached_download("STATES_GEOJSON"))
    rail = gtfs_de_stations()
    rail_index = NearestIndex(rail)
    print(f"  {len(rail)} stations")

    def rail_station(candidate: dict) -> dict:
        name = candidate["name"]
        sid = "name:" + name
        if sid not in stations:
            stations[sid] = {
                "stationId": sid,
                "dhid": None,
                "name": name,
                "region": states.region(candidate["point"]),
                "modes": [],
                "point": candidate["point"],
            }
        return stations[sid]

    records = []
    linked = by_stop_place = by_rail = 0
    unplaced: list[tuple[dict, str]] = []
    unknown_feeds: Counter = Counter()
    for e in elevators:
        point = centroid(e)
        site = relation_id((e.get("location") or {}).get("site"))
        station = None
        if site in stops_by_id:
            station = transit_station(stops_by_id[site])
            linked += 1
        elif point is not None:
            # Unlinked: the stop places come first — they carry the platform's
            # own names and DHIDs — then the rail stations of Germany.
            hit, _ = transit_index.nearest(point)
            if hit:
                station = transit_station(hit["stop"])
                by_stop_place += 1
            else:
                hit, _ = rail_index.nearest(point)
                if hit:
                    station = rail_station(hit)
                    by_rail += 1
        description = text((e.get("function") or {}).get("short_visual")) or text(e.get("internal_description"))
        if station is None:
            unplaced.append((e, description))
            continue
        feed = relation_id(e.get("feed"))
        if feed is not None and feed not in FEED_NAMES:
            unknown_feeds[feed] += 1
        operator = (e.get("linked_data") or {}).get("operator_org")
        inventory = (e.get("linked_data") or {}).get("operator_inventory_id")
        record = {
            "id": str(e["id"]),
            "inventoryId": str(inventory) if inventory else None,
            "stationId": station["stationId"],
            "stationName": station["name"],
            "stationModes": station["modes"],
            "region": station["region"],
            "description": description,
            "latitude": round(point[0], 6) if point else None,
            "longitude": round(point[1], 6) if point else None,
            "sourceName": FEED_NAMES.get(feed, ""),
            "organizationName": text(operator.get("name")) if isinstance(operator, dict) else "",
        }
        records.append({k: v for k, v in record.items() if v is not None})

    print(f"  {linked} linked upstream, {by_stop_place} placed at a stop place, "
          f"{by_rail} at a rail station, {len(unplaced)} unplaced (left out)")
    without_point = sum(1 for e, _ in unplaced if centroid(e) is None)
    print(f"    unplaced: {without_point} without centroid, {len(unplaced) - without_point} "
          f"further than {ASSIGN_RADIUS_M} m from any station", file=sys.stderr)
    for e, description in unplaced:
        if centroid(e) is not None:
            print(f"    {e['id']} {centroid(e)} — {description[:50]}", file=sys.stderr)
    for feed, count in unknown_feeds.items():
        print(f"  warning: feed {feed} ({count} elevators) has no name in FEED_NAMES", file=sys.stderr)

    # Stations the seed's elevators use, each with a coordinate: its own, or
    # the mean of its elevators' centroids where no GTFS knows it.
    used = {r["stationId"] for r in records}
    centroids = defaultdict(list)
    for r in records:
        if "latitude" in r:
            centroids[r["stationId"]].append((r["latitude"], r["longitude"]))
    station_list = []
    for sid in sorted(used):
        s = stations[sid]
        point = s["point"] or (mean(centroids[sid]) if centroids[sid] else None)
        if point is None:
            print(f"  station without coordinate: {sid} {s['name']}", file=sys.stderr)
            continue
        if s["region"] is None:
            print(f"  station without region: {sid} {s['name']}", file=sys.stderr)
        entry = {
            "stationId": sid,
            "dhid": s["dhid"],
            "name": s["name"],
            "region": s["region"],
            "latitude": round(point[0], 6),
            "longitude": round(point[1], 6),
        }
        station_list.append({k: v for k, v in entry.items() if v is not None})

    # Legacy ids only ever point at transit.accessibility.cloud records.
    legacy = legacy_ids(bundled, elevators, records)

    vrr_elevators, vrr_stations = vrr_block(bundled, station_list)
    records = records + vrr_elevators
    station_list = sorted(station_list + vrr_stations, key=lambda s: s["stationId"])

    report_name_collisions(station_list)
    print(f"  {len(records)} elevators at {len(station_list)} stations, "
          f"regions: {dict(Counter(r.get('region') for r in records).most_common())}")

    return {
        "version": FORMAT_VERSION,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "elevators": sorted(records, key=lambda r: seed_sort_key(r["id"])),
        "stations": station_list,
        "legacyIds": legacy,
    }


def report_name_collisions(stations: list[dict]) -> None:
    """The app groups search results by station name, so two stations far
    apart under one name would merge into one result. Diagnostics only."""
    by_name = defaultdict(list)
    for s in stations:
        by_name[s["name"]].append(s)
    for name, group in sorted(by_name.items()):
        if len(group) < 2:
            continue
        spread = max(haversine_m((a["latitude"], a["longitude"]), (b["latitude"], b["longitude"]))
                     for a in group for b in group)
        if spread > 1000:
            print(f"  name shared by stations {spread / 1000:.0f} km apart: {name}", file=sys.stderr)


def legacy_ids(bundled: dict | None, elevators: list[dict], records: list[dict]) -> dict[str, str]:
    live_ids = {str(e["id"]) for e in elevators}
    if not bundled:
        return {}
    if bundled.get("version", 1) >= 2:
        carried = {old: new for old, new in (bundled.get("legacyIds") or {}).items() if new in live_ids}
        carried.update({old: new for old, new in LEGACY_OVERRIDES.items() if new in live_ids})
        print(f"  {len(carried)} legacy ids carried over")
        return dict(sorted(carried.items()))
    # Format 1 → 2, once: by the operator inventory number first, then — for
    # stale numbers (DB renumbered, BVG's alphanumeric era) — by station and
    # description, which survived the migration nearly verbatim ("⟷" became
    # "↔", "Str." became "Straße"). Only unique matches count.
    by_inventory = {}
    for e in elevators:
        inventory = (e.get("linked_data") or {}).get("operator_inventory_id")
        if inventory:
            by_inventory.setdefault(str(inventory), str(e["id"]))
    by_station = defaultdict(list)
    for r in records:
        by_station[legacy_key(r["stationName"])].append(r)
    old = bundled.get("elevators", [])
    mapped, by_text = {}, 0
    for r in old:
        number = r.get("fastaEquipmentNumber")
        if number is not None and str(number) in by_inventory:
            mapped[r["id"]] = by_inventory[str(number)]
            continue
        text_key = legacy_text(r.get("description") or "")
        hits = [c for c in by_station.get(legacy_key(r.get("stationName") or ""), [])
                if text_key and legacy_text(c["description"]) == text_key]
        if len(hits) == 1:
            mapped[r["id"]] = hits[0]["id"]
            by_text += 1
    mapped.update({old_id: new for old_id, new in LEGACY_OVERRIDES.items() if new in live_ids})
    print(f"  {len(mapped)} of {len(old)} format-1 seed ids mapped to live ids "
          f"({by_text} by station and description, {len(LEGACY_OVERRIDES)} by hand)")
    for r in old:
        if r["id"] not in mapped:
            print(f"  format-1 id without live counterpart: {r['id']} {r.get('stationName')} — "
                  f"{(r.get('description') or '')[:50]}", file=sys.stderr)
    return dict(sorted(mapped.items()))


def legacy_key(name: str) -> str:
    folded = "".join(c for c in unicodedata.normalize("NFD", name) if not unicodedata.combining(c)).lower().strip()
    folded = re.sub(r"^(s\+u|u|s) ", "", folded)
    folded = folded.replace("ß", "ss").replace("str.", "strasse").replace(" bhf", "").replace("bahnhof", "")
    return re.sub(r"[^a-z0-9]", "", folded)


def legacy_text(description: str) -> str:
    return re.sub(r"[^a-z0-9]", "", description.lower().replace("ß", "ss").replace("str.", "strasse"))


def write(output: Path, seed: dict) -> None:
    """One record per line: small diffs, and about half the size of an
    indented file (the watch app bundles it too)."""
    def line(value) -> str:
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

    def block(items: list) -> str:
        return "[\n" + ",\n".join(" " + line(item) for item in items) + "\n]"

    legacy = seed["legacyIds"]
    legacy_block = "{\n" + ",\n".join(f" {line(k)}:{line(v)}" for k, v in legacy.items()) + "\n}" if legacy else "{}"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        "{\n"
        f"\"version\":{seed['version']},\n"
        f"\"generatedAt\":{line(seed['generatedAt'])},\n"
        f"\"elevators\":{block(seed['elevators'])},\n"
        f"\"stations\":{block(seed['stations'])},\n"
        f"\"legacyIds\":{legacy_block}\n"
        "}\n"
    )
    print(f"Wrote {output}")


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    output = Path(args[0]) if args else DEFAULT_OUTPUT
    # Stripped: a secret pasted with a trailing newline or space is the
    # same token, and the API would reject it as a different one.
    token = (os.environ.get("ACCESSIBILITY_CLOUD_APP_TOKEN")
             or secrets().get("accessibilityCloudAppToken", "")).strip()
    if not token.startswith("trtok_"):
        sys.exit("ACCESSIBILITY_CLOUD_APP_TOKEN is not a transit token (expected trtok_…)")
    bundled = json.loads(BUNDLED.read_text()) if BUNDLED.exists() else None
    write(output, build(token, bundled))


if __name__ == "__main__":
    main()
