#!/bin/sh
# App Store screenshots: prepares a simulator (clean status bar, Berlin
# location, fresh install), runs the screenshot UI test in the given
# language and converts the shots for App Store Connect.
#
#   scripts/screenshots.sh [device-name] [language] [region] [paired-phone]
#   scripts/screenshots.sh                                  # iPhone 18 Pro Max, de/DE
#   scripts/screenshots.sh "iPad Pro 13-inch (M5)"          # the iPad set
#   scripts/screenshots.sh "Apple Watch Series 12 (46mm)"   # the watch set
#
# iPhone/iPad: the device is erased, HissiUITests/ScreenshotTests taps
# through the app. Apple Watch: HissiWatchUITests/WatchScreenshotTests runs
# on the watch paired with [paired-phone] (default iPhone 18 Pro Max), which
# must have been through the iPhone run first — its favorites reach the
# watch via WatchConnectivity once the phone app is launched. The watch is
# not erased (that would break the pairing), only the app is reinstalled.
#
# Output: screenshots/<language>/<device>/raw/*.png (native size, gitignored)
# and *.jpg next to them, alpha-free and versioned; iPhone 6.9" shots are additionally scaled
# to the 6.5" slot (1284 x 2778) that App Store Connect asks for.
set -eu

DEVICE="${1:-iPhone 18 Pro Max}"
LANGUAGE="${2:-de}"
REGION="${3:-DE}"
PHONE="${4:-iPhone 18 Pro Max}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SLUG="$(printf '%s' "$DEVICE" | tr -c 'A-Za-z0-9' '-' | sed -E 's/-+/-/g; s/^-|-$//g')"
OUT="$REPO/screenshots/$LANGUAGE/$SLUG"
LOCATION="52.5219,13.4132"   # Alexanderplatz

udid_of() {   # device name -> UDID of the first available simulator
  xcrun simctl list devices available | grep -F "$1 (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

set_language() {   # UDID -> device language, so system prompts and keyboard match
  xcrun simctl spawn "$1" defaults write .GlobalPreferences AppleLanguages -array "$LANGUAGE" en
  xcrun simctl spawn "$1" defaults write .GlobalPreferences AppleLocale "${LANGUAGE}_${REGION}"
}

case "$DEVICE" in
  *"Apple Watch"*)
    # The pair whose watch and phone carry the given names.
    PAIR="$(xcrun simctl list pairs | awk -v w="$DEVICE (" -v p="$PHONE (" '
      /^    Watch:/ { watch = $0 }
      /^    Phone:/ { if (index(watch, w) && index($0, p)) { print watch; print $0; exit } }')"
    [ -n "$PAIR" ] || { echo "error: no simulator pair of '$DEVICE' with '$PHONE' (xcrun simctl list pairs)" >&2; exit 1; }
    UDID="$(printf '%s\n' "$PAIR" | sed -n '1p' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
    PHONE_UDID="$(printf '%s\n' "$PAIR" | sed -n '2p' | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"

    xcrun simctl boot "$PHONE_UDID" 2>/dev/null || true
    xcrun simctl boot "$UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$PHONE_UDID" -b >/dev/null
    xcrun simctl bootstatus "$UDID" -b >/dev/null
    xcrun simctl get_app_container "$PHONE_UDID" com.a11yland.Hissi >/dev/null 2>&1 \
      || { echo "error: Hissi is not installed on '$PHONE' — run the iPhone set on it first" >&2; exit 1; }
    set_language "$UDID"
    xcrun simctl location "$UDID" set "$LOCATION" 2>/dev/null || true
    # Build and install the watch app *before* the phone app runs: the phone
    # only pushes the favorites (updateApplicationContext) while it sees a
    # watch app installed, so the install order decides whether the list
    # has favorites.
    SCHEME=HissiWatchScreenshots
    xcodebuild build-for-testing -project "$REPO/Hissi.xcodeproj" -scheme "$SCHEME" -destination "id=$UDID" \
      2>&1 | grep --line-buffered -E "error:|BUILD" || true
    PRODUCTS="$(xcodebuild -project "$REPO/Hissi.xcodeproj" -scheme "$SCHEME" -destination "id=$UDID" \
      -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR = / {print $3; exit}')"
    xcrun simctl uninstall "$UDID" com.a11yland.Hissi.watchkitapp 2>/dev/null || true
    xcrun simctl install "$UDID" "$PRODUCTS/HissiWatch.app"
    xcrun simctl launch "$UDID" com.a11yland.Hissi.watchkitapp >/dev/null   # activates the WCSession
    sleep 5
    xcrun simctl terminate "$PHONE_UDID" com.a11yland.Hissi 2>/dev/null || true
    xcrun simctl launch "$PHONE_UDID" com.a11yland.Hissi >/dev/null          # refresh -> push to the watch
    sleep 15
    xcrun simctl terminate "$UDID" com.a11yland.Hissi.watchkitapp 2>/dev/null || true
    XCTESTRUN="$(ls -t "$PRODUCTS"/../"$SCHEME"_*.xctestrun | head -1)"
    ;;
  *)
    UDID="$(udid_of "$DEVICE")"
    [ -n "$UDID" ] || { echo "error: no available simulator named '$DEVICE'" >&2; exit 1; }
    # Erase, not just uninstall: App Group data (favorites, catalog cache)
    # and the local iCloud key-value store survive an uninstall, and a fresh
    # device is what the first screenshot (welcome) assumes.
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    xcrun simctl erase "$UDID"
    xcrun simctl boot "$UDID"
    xcrun simctl bootstatus "$UDID" -b >/dev/null
    set_language "$UDID"
    xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 \
      --cellularMode active --cellularBars 4 --wifiBars 3 --operatorName ""
    xcrun simctl location "$UDID" set "$LOCATION"
    SCHEME=HissiScreenshots
    ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT/raw"

if [ -n "${XCTESTRUN:-}" ]; then
  TEST_RUNNER_SCREENSHOT_DIR="$OUT/raw" xcodebuild test-without-building -xctestrun "$XCTESTRUN" \
    -destination "id=$UDID" -testLanguage "$LANGUAGE" -testRegion "$REGION" \
    2>&1 | grep --line-buffered -E "Test Case|error:|Executed|BUILD|TEST" || true
else
  TEST_RUNNER_SCREENSHOT_DIR="$OUT/raw" xcodebuild test \
    -project "$REPO/Hissi.xcodeproj" -scheme "$SCHEME" \
    -destination "id=$UDID" -testLanguage "$LANGUAGE" -testRegion "$REGION" \
    2>&1 | grep --line-buffered -E "Test Case|error:|Executed|BUILD|TEST" || true
fi

for png in "$OUT"/raw/*.png; do
  [ -e "$png" ] || { echo "error: no screenshots were written" >&2; exit 1; }
  name="$(basename "$png" .png)"
  width="$(sips -g pixelWidth "$png" | awk '/pixelWidth/ {print $2}')"
  if [ "$width" = "1320" ]; then
    # 6.9" (1320 x 2868) -> 6.5" slot (1284 x 2778): scale to width, trim 12 px.
    sips -s format jpeg -s formatOptions 95 -z 2790 1284 "$png" --out "$OUT/$name.jpg" >/dev/null
    sips -c 2778 1284 "$OUT/$name.jpg" >/dev/null
  else
    sips -s format jpeg -s formatOptions 95 "$png" --out "$OUT/$name.jpg" >/dev/null
  fi
done

echo "Screenshots in $OUT"
ls "$OUT"/*.jpg
