# Business Requirements

Hissi answers one question for people who depend on elevators — wheelchair
users, parents with strollers, travelers with luggage, anyone avoiding stairs:
**"Will the elevators on my route work, right now?"** for public transit in
Berlin and Brandenburg (VBB).

How these requirements are implemented is described in
[`architecture.md`](architecture.md).

## Users

| Persona | Need |
|---------|------|
| Wheelchair user, daily commuter | Know before departing whether the route's elevators run; alternatives cost real time |
| Stroller parent / traveler with luggage | Quick pre-trip check of one or two stations |
| Caregiver | Check the status of stations a dependent person uses |

## Use cases

**UC1 — Plan an accessible trip.** Search a station by name, see every elevator
there with live status, position (which platform/exit) and location on a map —
before leaving home. Stations are grouped by region (Berlin/Brandenburg) and,
at S+U stations, split by network (U-Bahn/S-Bahn/Regionalverkehr), because "the
S-Bahn elevator works" and "the U-Bahn elevator works" are different answers.

**UC2 — Monitor the daily route.** Mark elevators as favorites once; afterwards
one glance at the list shows all of them with status and when they were last
checked. No accounts, no setup beyond picking favorites — and picking them
survives a reinstall or a new phone.

**UC3 — Glance without opening the app.** The home screen widget shows the
broken/unknown count (or "all working"); watch complications show the same from
the wrist. Complications require a paired iPhone with at least one favorite —
without favorites (or before the first sync) the status complication shows the
app's logo rather than a placeholder verdict.

**UC4 — Understand a disruption.** For a broken elevator: the operator's German
disruption text, the data source, the operator, how fresh the information is,
and the station location for planning a detour.

**UC6 — Find a working elevator nearby, on the go.** Standing somewhere in
the city: which stations within walking distance have elevators, and do they
work? Answered from the search's nearby block, from the wrist (a complication
opens it directly), and from a home screen widget — with the phone or the
watch alone.

**UC5 — Degraded conditions.** With no network or failing sources, the app
still searches (bundled catalog) and shows the last known status from cache —
clearly marked as possibly outdated, never silently fabricated.

## Functional requirements

| # | Requirement | UC |
|---|-------------|----|
| FR1 | Search all VBB-area station elevators by name, without an account | UC1 |
| FR2 | Group results region → station → network; split S+U stations per elevator; shared entrance elevators form their own group | UC1 |
| FR3 | Show live status in search results and pre-favorite detail, not only for favorites | UC1 |
| FR4 | Favorites are created and managed only in the iOS app (iPhone, and the same app on iPad and Mac); widget, watch and complications mirror them read-only | UC2, UC3 |
| FR4a | Favorites survive deleting and reinstalling the app and follow the user to their other devices (iPhone, iPad, Mac) through their own iCloud — no Hissi account, and without iCloud everything keeps working locally. A change on one device reaches the others, removals included. A successor app from the same developer under another name takes the favorites over on its first launch | UC2 |
| FR4b | The favorites can be exported as a file (share sheet: Files, AirDrop, Mail) — a backup the user holds, and the way to a successor app that shares no iCloud store with this one. Versioned format, statuses left out. Export-only: Hissi itself imports no file (FR4) | UC2 |
| FR5 | Refresh all favorites together: automatically every 30 min, on app open/foreground, manually on demand, and in the background so widget/watch stay fresh between sessions | UC2, UC3 |
| FR6 | Favorite changes reach widget and watch immediately | UC2, UC3 |
| FR7 | Per elevator, distinguish three states: working / broken / unknown | all |
| FR8 | While broken, show the disruption reason (German where available); never show a stale reason on a working elevator | UC4 |
| FR9 | Show two timestamps: when the app last polled, and how fresh the source data is; warn when source data is older than 14 days | UC2, UC4, UC5 |
| FR10 | On source failure, keep the previous values, mark the elevator as not refreshed, and tell the user | UC5 |
| FR11 | Search works offline from a bundled catalog (status unknown); status surfaces fall back to the last cached state | UC5 |
| FR12 | Show station location on a tappable map that hands off to the Maps app | UC1, UC4 |
| FR13 | Complications answer "is my route okay?" with one aggregate verdict across all favorites (all working / n broken / unknown); per-elevator detail lives in the watch app | UC3 |
| FR14 | Complications show the aggregate status only (OK / broken count / unknown) — no data-age display; freshness comes from the refresh cadence (FR5) | UC3 |
| FR15 | Complications are available in all four watch face families (circular, rectangular, inline, corner) so the info fits any face layout, and in the watch Smart Stack | UC3 |
| FR15a | The same aggregate verdict is available on the iPhone lock screen (circular, rectangular, inline) — the surface the user sees without unlocking, i.e. on the platform | UC3 |
| FR15b | Glanceable surfaces rank themselves inside a stack by how bad the news is: a broken elevator surfaces on its own, an all-clear never displaces what the user put there | UC3 |
| FR16 | Complications identify the app by its logo, not its name: the rectangular and inline families carry the logo next to the status, the nearby complication shows the logo alone in the small families; the status complication's circular and corner families reserve their space for the status (shape, word, colour gauge) — placement on the face is the identity there. VoiceOver never says "Hissi" (the system doesn't either); the sentence names the subject instead: "2 Lifte außer Betrieb", "Alle Lifte in Betrieb", "Lifte in der Nähe" | UC3 |
| FR16a | Without favorites the status complication shows the logo alone (circular, corner) or the logo next to "Keine Favoriten" (rectangular, inline); VoiceOver reads "Keine Lift-Favoriten" | UC3 |
| FR17 | Search answers instantly from the newest locally available data and updates to live status once the refresh lands — the pending refresh is visibly signaled so shown statuses never look final while an update is under way; on the very first launch the bundled catalog previews names read-only (no favoriting) until live data arrives | UC1, UC5 |
| FR18 | First launch shows a one-time welcome introducing search, favorites and widget/watch; releases with curated notes show a one-time "What's New" sheet — releases without stay silent | UC1–UC3 |
| FR19 | With the user's explicit opt-in (contextual button, when-in-use permission), the app suggests stations **within walking distance** (1 km) with their lift status; the radius is named in the UI, and "nothing within reach" is said as such instead of listing a station a car ride away; the location is used on-device only and never stored or transmitted (see Q3) | UC1, UC6 |
| FR19a | The nearby entry point is always reachable in the iPhone app — under the empty favorites state and above the favorites list — and opens the location fix together with the search | UC6 |
| FR19b | The watch answers nearby on its own (own location, own catalog) so it works without the phone in reach: a nearby screen above the favorites list, and a dedicated "In der Nähe" complication that opens it from the face; tapping a station shows its elevators | UC6 |
| FR19c | A home screen widget shows the nearby stations and their status (nearest only / list), reusing the catalog the app built — the widget never builds one itself; without location extended to the widget it says so | UC6 |
| FR20 | The app answers "is my route okay?" without being opened: ready-made shortcuts (Shortcuts app, Spotlight, Siri) report the aggregate verdict and any single favorite, and are available without the user configuring anything | UC2, UC3 |
| FR20a | The single-elevator shortcut hands the checked elevator on as a value; where the system supports it, it travels into other apps as a *place* (station name + coordinates) — e.g. into directions when the elevator is broken. Export-only: nothing imports elevators or favorites (FR4), and without coordinates no place is offered rather than a wrong one (D3's spirit) | UC2, UC4 |
| FR21 | On request the user starts a **live status** for a trip: a Live Activity shows the aggregate verdict plus the most urgent favorites on the Lock Screen and in the Dynamic Island. It is started by the user, ends on its own (fixed duration, or as soon as nothing is broken any more) and can be stopped from the activity itself | UC2, UC3 |
| FR21c | A running live status also appears in the watch's Smart Stack, in the same shape as the status complication (logo, verdict, station) plus its countdown and outdated marker; it is stopped from the phone, the watch shows it only | UC3 |
| FR21a | A running live status **alerts** when a monitored elevator breaks down or works again — the app's only active warning, so it fires on real changes only, never re-announcing a standing disruption | UC2, UC4 |
| FR21b | A live status never presents an outdated status as current: without a push server its updates ride the refresh cadence, so it marks itself as possibly outdated once an update is overdue | UC5 |

## Data requirements

| # | Requirement |
|---|-------------|
| D1 | Single status source: transit.accessibility.cloud aggregates the operator feeds (incl. DB FaSta, BVG) itself. The former client-side multi-source merge (FaSta override, brokenlifts.org scraping) existed only to compensate the old API's gaps and is retired |
| D2 | Stations the platform still lacks (currently S Fredersdorf) stay searchable with unknown status via the bundled seed and are reported upstream — coverage gaps are upstream's to fix, not the app's to patch |
| D3 | "Unknown" beats a wrong answer: a source with dead status data must surface as status-unknown, never as a false "working" |
| D4 | Coverage is Berlin + Brandenburg; stations outside (Magdeburg, Leipzig, …) must not appear even when upstream feeds carry them |

## Quality requirements

| # | Requirement |
|---|-------------|
| Q1 | The UI is fully available in German and English, switchable per app via the iOS system language setting (Settings → Hissi → Language); station information (elevator descriptions) follows the chosen language where the sources provide it, falling back to German |
| Q2 | Fully usable with VoiceOver; status is never conveyed by color alone |
| Q3 | No accounts, no tracking; favorites stay on the user's devices and in their own iCloud (FR4a), never on a server of ours |
| Q4 | Be a polite API citizen: bounded request volume (shared refresh cadence, one targeted request per favorites refresh, cached and disk-persisted search catalog, `select[]`-trimmed responses) |
| Q5 | Background refresh fits iOS budgets so widget and complications stay useful without draining battery |
| Q6 | Touch targets meet 44 pt (WCAG 2.2 SC 2.5.5, AAA); every colour that carries text — the tint (buttons, links) on each ground it appears on, the white letter on the network badges — meets AAA contrast (SC 1.4.6, 7:1), guarded by a unit test; the status colours stay at AA for now |

## Out of scope

- Routing/trip planning — the app informs about elevators; navigation stays in
  transit/maps apps
- A push server: no backend, no push tokens, no accounts (Q3). This bounds what
  the live status (FR21) can do — it cannot start itself when a disruption
  appears, and its updates are only as frequent as the app's own refreshes
  (FR21b)
- Reporting defects to operators
- Escalators (elevator category only)
- Coverage beyond VBB territory
