#!/bin/sh
# App Store screenshots: for every device and language, prepares the target
# (simulator: erased, clean status bar, Alexanderplatz as location, device
# language), runs the screenshot UI test in demo mode (fixed catalog and
# statuses, see Shared/DemoMode.swift) and converts the shots for App Store
# Connect.
#
#   scripts/screenshots.sh [--lang de,en] [device…]
#   scripts/screenshots.sh                                  # every device, de + en
#   scripts/screenshots.sh "iPhone 18 Pro" --lang de        # one set
#   scripts/screenshots.sh Mac                              # Mac Catalyst on this Mac
#
# Devices: simulator names, `Mac`, or `all` (the default): iPhone 18 Pro
# (6.3", 1206 x 2622 — the size App Store Connect's iPhone slot takes),
# iPad Pro 13-inch (M5), iPhone Duo, Apple Watch Series 12 (46mm) —
# not yet the Mac, whose unsigned test runner doesn't connect (CLAUDE.md).
# iPhone/iPad/Duo run HissiUITests/ScreenshotTests (scheme HissiScreenshots),
# the watch HissiWatchUITests/WatchScreenshotTests (HissiWatchScreenshots) —
# the watch is only reinstalled, never erased (that would break its pairing).
# The Mac run builds unsigned and unsandboxed, so it never touches the real
# app's containers.
#
# Output: screenshots/<language>/<device>/raw/*.png (native size, gitignored)
# and *.jpg next to them, alpha-free and versioned. Derived on the way:
# 08-without-color (01-favorites in greyscale — the statuses read by shape),
# iPhone 6.9" shots scaled to the 6.5" slot (1284 x 2778), Mac window shots
# centred on a 2880 x 1800 canvas.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LANGUAGES="de en"
DEVICES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lang) LANGUAGES="$(printf '%s' "$2" | tr ',' ' ')"; shift 2 ;;
    *) DEVICES="$DEVICES
$1"; shift ;;
  esac
done
DEVICES="$(printf '%s\n' "$DEVICES" | sed '/^$/d')"
if [ -z "$DEVICES" ] || [ "$DEVICES" = all ]; then
  DEVICES="iPhone 18 Pro
iPad Pro 13-inch (M5)
iPhone Duo
Apple Watch Series 12 (46mm)"
fi

LOCATION="52.5219,13.4132"   # Alexanderplatz — DemoFixtures' nearby stations
BACKGROUND="FBF3E4"          # HissiBackground (light), the Mac canvas
DERIVED="$REPO/build/screenshots"

region_of() { case "$1" in en) echo US ;; *) echo DE ;; esac; }

udid_of() {   # device name -> UDID of the first available simulator
  xcrun simctl list devices available | grep -F "$1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

slug_of() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '-' | sed -E 's/-+/-/g; s/^-|-$//g'; }

prepare_simulator() {   # UDID language erase(yes|no)
  if [ "$3" = yes ]; then
    # Erase, not just uninstall: App Group data, the location permission
    # and widgets placed by an earlier run survive an uninstall.
    xcrun simctl shutdown "$1" 2>/dev/null || true
    xcrun simctl erase "$1"
  fi
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b >/dev/null
  xcrun simctl spawn "$1" defaults write .GlobalPreferences AppleLanguages -array "$2" en
  xcrun simctl spawn "$1" defaults write .GlobalPreferences AppleLocale "${2}_$(region_of "$2")"
  # The system UI (alerts, SpringBoard, Lock Screen) only picks the
  # language up on the next boot.
  xcrun simctl shutdown "$1"
  xcrun simctl boot "$1"
  xcrun simctl bootstatus "$1" -b >/dev/null
  xcrun simctl status_bar "$1" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiBars 3 --operatorName "" 2>/dev/null || true
  xcrun simctl location "$1" set "$LOCATION" 2>/dev/null || true
}

build_for_testing() {   # scheme destination [build settings…] -> path of the .xctestrun
  scheme="$1" destination="$2"
  shift 2
  xcodebuild build-for-testing -project "$REPO/Hissi.xcodeproj" -scheme "$scheme" -destination "$destination" \
    -derivedDataPath "$DERIVED" "$@" 2>&1 | grep --line-buffered -E "error:|BUILD" >&2 || true
  ls -t "$DERIVED"/Build/Products/"$scheme"_*.xctestrun 2>/dev/null | head -1
}

run_tests() {   # xctestrun destination language output-dir
  mkdir -p "$4/raw"
  TEST_RUNNER_SCREENSHOT_DIR="$4/raw" xcodebuild test-without-building -xctestrun "$1" \
    -destination "$2" -testLanguage "$3" -testRegion "$(region_of "$3")" \
    -retry-tests-on-failure -test-iterations 3 \
    2>&1 | grep --line-buffered -E "Test Case|error:|Executed|skipped" || true
}

convert() {   # output-dir
  for png in "$1"/raw/*.png; do
    [ -e "$png" ] || { echo "error: no screenshots were written to $1" >&2; return 1; }
    name="$(basename "$png" .png)"
    case "$name" in failure-*) continue ;; esac
    width="$(sips -g pixelWidth "$png" | awk '/pixelWidth/ {print $2}')"
    if [ "$width" = "1320" ]; then
      # 6.9" (1320 x 2868) -> 6.5" slot (1284 x 2778): scale to width, trim 12 px.
      sips -s format jpeg -s formatOptions 95 -z 2790 1284 "$png" --out "$1/$name.jpg" >/dev/null
      sips -c 2778 1284 "$1/$name.jpg" >/dev/null
    else
      sips -s format jpeg -s formatOptions 95 "$png" --out "$1/$name.jpg" >/dev/null
    fi
  done
  if [ -e "$1/01-favorites.jpg" ]; then
    # Through a grey profile and back to sRGB: App Store Connect wants RGB.
    sips --matchTo "/System/Library/ColorSync/Profiles/Generic Gray Gamma 2.2 Profile.icc" \
      "$1/01-favorites.jpg" --out "$1/08-without-color.jpg" >/dev/null
    sips --matchTo "/System/Library/ColorSync/Profiles/sRGB Profile.icc" "$1/08-without-color.jpg" >/dev/null
  fi
}

mac_canvas() {   # output-dir: window shots -> 2880 x 1800, window at most 2560 x 1600
  for jpg in "$1"/*.jpg; do
    w="$(sips -g pixelWidth "$jpg" | awk '/pixelWidth/ {print $2}')"
    h="$(sips -g pixelHeight "$jpg" | awk '/pixelHeight/ {print $2}')"
    if [ "$w" -gt 2560 ] || [ "$h" -gt 1600 ]; then
      if [ $((w * 1600)) -gt $((h * 2560)) ]; then sips --resampleWidth 2560 "$jpg" >/dev/null
      else sips --resampleHeight 1600 "$jpg" >/dev/null; fi
    fi
    sips -p 1800 2880 --padColor "$BACKGROUND" "$jpg" >/dev/null
  done
}

shoot_watch() {   # device-name
  udid="$(udid_of "$1")"
  [ -n "$udid" ] || { echo "error: no available simulator named '$1'" >&2; return 1; }
  prepare_simulator "$udid" de no
  xctestrun="$(build_for_testing HissiWatchScreenshots "id=$udid")"
  for language in $LANGUAGES; do
    out="$REPO/screenshots/$language/$(slug_of "$1")"
    rm -rf "$out"
    prepare_simulator "$udid" "$language" no
    xcrun simctl uninstall "$udid" com.a11yland.Hissi.watchkitapp 2>/dev/null || true
    run_tests "$xctestrun" "id=$udid" "$language" "$out"
    convert "$out"
  done
}

shoot_simulator() {   # device-name
  udid="$(udid_of "$1")"
  [ -n "$udid" ] || { echo "error: no available simulator named '$1'" >&2; return 1; }
  case "$1" in *Duo*) echo "note: iPhone Duo shoots in the pose the simulator starts in — switch poses by hand" ;; esac
  prepare_simulator "$udid" de no
  xctestrun="$(build_for_testing HissiScreenshots "id=$udid")"
  for language in $LANGUAGES; do
    out="$REPO/screenshots/$language/$(slug_of "$1")"
    rm -rf "$out"
    prepare_simulator "$udid" "$language" yes
    run_tests "$xctestrun" "id=$udid" "$language" "$out"
    convert "$out"
  done
}

shoot_mac() {
  destination="platform=macOS,variant=Mac Catalyst"
  # Unsigned (the linker signs ad hoc) and without entitlements: a Mac
  # Catalyst development profile needs a "Mac Development" certificate, and
  # demo mode needs neither the App Group nor iCloud. Unsandboxed, the app
  # never touches the real app's containers — its stores fall back to the
  # standard defaults.
  xctestrun="$(build_for_testing HissiScreenshots "$destination" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_ENTITLEMENTS= ENABLE_HARDENED_RUNTIME=NO)"
  for language in $LANGUAGES; do
    out="$REPO/screenshots/$language/Mac"
    rm -rf "$out"
    run_tests "$xctestrun" "$destination" "$language" "$out"
    convert "$out"
    mac_canvas "$out"
  done
}

# Not `| while read`: xcodebuild and simctl would eat the list from stdin.
IFS='
'
for device in $DEVICES; do
  IFS=' 	
'
  echo "== $device ($LANGUAGES)"
  case "$device" in
    Mac) shoot_mac ;;
    *"Apple Watch"*) shoot_watch "$device" ;;
    *) shoot_simulator "$device" ;;
  esac || echo "error: $device failed" >&2
done

echo "Screenshots in $REPO/screenshots"
