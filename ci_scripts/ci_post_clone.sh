#!/bin/sh
# Xcode Cloud runs this automatically after cloning the repository.
#
# Shared/Secrets.swift is gitignored (see Secrets.example.swift), so it is
# absent on a fresh clone and the build fails with "Cannot find 'Secrets' in
# scope". Regenerate it here from the API credentials, provided as Xcode Cloud
# environment variables (mark them Secret):
#   ACCESSIBILITY_CLOUD_APP_TOKEN — transit.accessibility.cloud app token
#     (Bearer, "trtok_…")
# An unset variable becomes an empty string; the API then answers 403 and the
# app falls back to the bundled seed catalog. If no variable is set at all,
# fall back to the checked-in template — mirroring the CI step in
# .github/workflows/ios.yml.
set -eu

REPO="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
DEST="$REPO/Shared/Secrets.swift"

# transit.accessibility.cloud tokens are Bearer tokens of the form "trtok_…".
# A value in the old 32-hex format means the Xcode Cloud environment variable
# was not updated after the API migration — fail loudly instead of shipping a
# build whose every request 403s and silently falls back to the seed.
case "${ACCESSIBILITY_CLOUD_APP_TOKEN:-trtok_unset}" in
  trtok_*) ;;
  *) echo "error: ACCESSIBILITY_CLOUD_APP_TOKEN is not a transit token (expected trtok_…)." \
          "Update the Xcode Cloud environment variable." >&2
     exit 1 ;;
esac

if [ -n "${ACCESSIBILITY_CLOUD_APP_TOKEN:-}" ]; then
  cat > "$DEST" <<EOF
import Foundation

enum Secrets {
    nonisolated static let accessibilityCloudAppToken = "${ACCESSIBILITY_CLOUD_APP_TOKEN:-}"
}
EOF
  echo "Generated Shared/Secrets.swift from environment variables."
else
  cp "$REPO/Secrets.example.swift" "$DEST"
  echo "No secret environment variables set; copied Secrets.example.swift (empty values)."
fi
