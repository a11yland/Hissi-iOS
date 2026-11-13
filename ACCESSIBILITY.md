# Accessibility

Hissi tells people whether the elevators at Berlin and Brandenburg stations work. It is built for wheelchair users, parents with strollers and everyone travelling with luggage, so accessibility is the core of the product, not an add-on.

## Accessibility priorities

**Target state:** WCAG 2.2 Level AA is the required minimum for every change. Level AAA is a bonus goal: meet AAA success criteria wherever feasible (for example enhanced contrast of 7:1 for text, 1.4.6; target size of at least 44 by 44 points, 2.5.5; no timing, 2.2.3; visible focus not obscured at all, 2.4.12), but missing AAA alone does not block a release. Conformance has not been formally audited yet; the Known barriers section lists where the project falls short of this target.

What the code does today:

- **VoiceOver.** Icon-only controls carry labels (refresh, sort, appearance toggle, live status bell, favorite star, "Über Hissi"). Decorative images and status symbols are hidden; the status is spoken as words. Rows and cards are combined into one element each, mode headlines and sheet titles carry the header trait, and network badges ("U", "S", "R") are spelled out as "U-Bahn", "S-Bahn", "Regionalbahn". Reordering favorites by drag is also offered as "Nach oben bewegen" / "Nach unten bewegen" accessibility actions, with the new position announced. Refresh errors and the "Status wird aktualisiert …" banners are announced (`AccessibilityNotification.Announcement`). So is a refresh's outcome (`RefreshAnnouncement`): a pull-to-refresh or the refresh button always answers, with "Aktualisiert, keine Änderung" or the status change in the live status alert's words ("Aufzug außer Betrieb: S+U Pankow"); a routine poll speaks only on a real status change. Back from an elevator's detail, focus returns to the row it was opened from: the detail is a `NavigationStack` push, and the system restores the focus on pop (not yet checked with VoiceOver on a device). The map snippet and the Look Around preview have their own labels and hints.
- **Voice Control.** Buttons use visible text where possible; the map snippet accepts "In Karten öffnen" and "Karte" as input labels (`accessibilityInputLabels` in `ElevatorDetailView`).
- **Dynamic Type.** Text uses system text styles. Layouts that would not fit at accessibility sizes switch to a stacked fallback via `ViewThatFits` (favorites headline, live status start buttons), icon columns scale with `@ScaledMetric` (`FeatureRow`), station names and statuses wrap to two lines, and recent-search chips are capped at the container width.
- **Dark Mode.** Every colour is a light/dark pair in `Shared/Colors.xcassets`; the app follows the system and offers a session-only light/dark toggle in the toolbar. The watch uses a dark palette.
- **Differentiate Without Color.** Each status has its own shape (circle with check, square with question mark, cross; `ElevatorStatus.symbolName`) plus a word. Lock Screen and accessory widgets never rely on colour. The favorite star and map pin are lilac, not yellow or red, because those colours mean "unknown" and "out of service".
- **Contrast.** The tint is 7:1 (AAA) as text on every ground, status words are at least 4.5:1, status symbols at least 3:1, and the white letters on network badges 7:1. `HissiTests/Tests/PaletteTests.swift` reads the colour sets and fails the build if any of these drop. Pills drawn over the map use an opaque background, because a translucent material guarantees no ratio.
- **Target size.** Pinned actions, recent-search chips, the live status start buttons and the favorite star in search results are at least 44 points tall (`.controlSize(.large)` or an explicit frame).
- **Reduce Motion.** The map camera move after a location fix is unanimated when Reduce Motion is on. Other transitions are crossfades.
- **Widgets, Live Activity and Watch.** Every widget unit is one VoiceOver element with a full sentence; accessory families that show no app name identify the app in their label. The Live Activity has labelled end and status controls. The watch app and complications have spoken labels, the nearby complication a hint, and the watch colours are set as dark-mode constants.

The **Accessibility Nutrition Labels** declared in App Store Connect claim VoiceOver, Voice Control, Larger Text, Dark Interface, Differentiate Without Color Alone, Sufficient Contrast and Reduced Motion for iPhone and iPad, and the same set without Voice Control for Apple Watch. Every change must keep these claims true.

## Supported environments

- iPhone and iPad with iOS/iPadOS 18 or later, portrait and landscape
- Mac via Mac Catalyst (shares the iOS code; no Live Activity, no watch)
- Apple Watch with watchOS 10 or later, including complications and the Smart Stack
- Home Screen and Lock Screen widgets, StandBy, Live Activity and Dynamic Island
- App Shortcuts for Siri, Spotlight and the Shortcuts app
- Languages: German (source) and English
- Assistive technologies the code is written for: VoiceOver, Voice Control (iPhone/iPad), Switch Control (through the same accessibility actions), Dynamic Type including accessibility sizes, Dark Mode, Reduce Motion

## Known barriers

All open items are tracked as [issues with the `a11y` label](https://github.com/a11yland/Hissi-iOS/issues?q=is%3Aissue+is%3Aopen+label%3Aa11y).

Tracked in [#3 Close the gaps behind the Accessibility Nutrition Labels](https://github.com/a11yland/Hissi-iOS/issues/3). The code fixes for contrast, the map input label, Reduce Motion, the four Larger Text spots and the banner announcement have landed; still open there:

- Voice Control on a device: swipe "Entfernen", the reorder actions, the recent-search chip context menu via "Show actions", search and the favorite star have not been verified.

Found in a code review and not yet covered by #3:

- **Larger Text** ([#7](https://github.com/a11yland/Hissi-iOS/issues/7)). The "In der Nähe" header row puts up to four items side by side; the map snippet has a fixed height of 160 points with two text pills that can collide at large sizes; the live status sheet sizes itself to its content without a scroll view; the watch elevator page has no scroll view and cuts the disruption reason at three lines.
- **Target size (AAA)** ([#8](https://github.com/a11yland/Hissi-iOS/issues/8)). A few controls stay below 44 points: the "Meinen Standort anzeigen" pill on the map, the "Einstellungen öffnen" link when location access is denied, and the "Fertig" button in the live status sheet.
- **Headings** ([#9](https://github.com/a11yland/Hissi-iOS/issues/9)). The "In der Nähe" and "Letzte Suchen" section titles on the search screen are not marked as headers, so the VoiceOver rotor skips them.
- **Contrast** ([#10](https://github.com/a11yland/Hissi-iOS/issues/10)). The refresh error on the favorites list is drawn over the rows without a background, so its contrast depends on what is underneath. The watch colour constants are not covered by `PaletteTests`.
- **Feedback** ([#11](https://github.com/a11yland/Hissi-iOS/issues/11)). The app itself offers no way to report an accessibility problem.

## Contributor expectations

- Every change meets WCAG 2.2 AA. Aim for AAA where feasible.
- Read this file before any UI change and update **Known barriers** when you add, find or fix one.
- Give every icon-only control an `accessibilityLabel`; hide decorative images; combine rows into one element with a sentence that makes sense on its own.
- Never convey status by colour alone. Use the status shape and word from `ElevatorStatus`.
- Use colours from `Shared/Colors.xcassets` / `Color.hissi…`, not `.secondary` or `.tertiary`. Add new text or symbol colours to `PaletteTests`.
- Use system text styles, no fixed font sizes in the app. Check the largest accessibility text size and offer a stacked layout where a row no longer fits.
- Make touch targets at least 44 by 44 points.
- Offer every gesture-only action (drag, swipe, long press) as an accessibility action too.
- Guard non-essential animation with `accessibilityReduceMotion`.
- Add `accessibilityInputLabels` when the spoken name of a control differs from its visible text.
- Test with VoiceOver and the largest text size on iPhone, and with VoiceOver on Apple Watch, before opening a pull request that touches UI.

## Reporting process

Report accessibility problems as an issue on [github.com/a11yland/Hissi-iOS/issues](https://github.com/a11yland/Hissi-iOS/issues). **Every accessibility issue must have the `a11y` label** so it can be found and triaged. Please include:

- device and system version (iPhone, iPad, Mac or Apple Watch)
- the assistive technology or setting in use (for example VoiceOver, Voice Control, text size)
- the screen or widget and what you expected to happen

If you do not use GitHub, write to the contact address in [PRIVACY.md](PRIVACY.md); the report will be filed as an issue for you.

## Ownership

The a11yland maintainers (Kobe) own the accessibility of Hissi. They triage `a11y` issues and decide on fixes and releases.

## Maintenance

- Review this file with every release and whenever an `a11y` issue is opened or closed.
- Keep **Known barriers** in step with the open `a11y` issues.
- Re-check the Accessibility Nutrition Labels in App Store Connect after a release that touches UI, and remove a claim if it no longer holds.
