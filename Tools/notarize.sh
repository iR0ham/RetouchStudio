#!/bin/bash
# Submits a signed app or DMG to Apple for notarization and staples the ticket.
#
#   RETOUCH_NOTARY_PROFILE=retouch-notary Tools/notarize.sh "Retouch Studio.app"
#   RETOUCH_NOTARY_PROFILE=retouch-notary Tools/notarize.sh RetouchStudio-1.0.0-universal.dmg
#
# The profile is a notarytool keychain profile created once by the owner:
#   xcrun notarytool store-credentials retouch-notary \
#     --apple-id <id> --team-id <team> --password <app-specific-password>
#
# No credentials belong in this repository. Without a profile this script
# refuses instead of pretending the build was notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:?usage: Tools/notarize.sh <app-or-dmg>}"
[ -e "$TARGET" ] || { echo "✗ not found: $TARGET" >&2; exit 1; }

PROFILE="${RETOUCH_NOTARY_PROFILE:-}"
if [ -z "$PROFILE" ]; then
  echo "✗ notarization needs RETOUCH_NOTARY_PROFILE (a notarytool keychain profile)." >&2
  echo "  Nothing was submitted. See Docs/RELEASING.md." >&2
  exit 2
fi

case "$TARGET" in
  *.dmg) ASSESS_TYPE=install ;;
  *.app) ASSESS_TYPE=execute ;;
  *) echo "✗ expected a .app or .dmg, got: $TARGET" >&2; exit 1 ;;
esac

# A disk image is not a codesign target; its payload is what Apple inspects.
# Checking the .app up front turns the common mistake into a local error
# instead of a rejected submission.
if [ "$ASSESS_TYPE" = execute ]; then
  SIGNATURE=$(codesign -dv --verbose=2 "$TARGET" 2>&1 || true)
  if ! printf '%s' "$SIGNATURE" | grep -q "Authority=Developer ID"; then
    echo "✗ notarization needs a Developer ID signature; ad-hoc builds cannot be notarized." >&2
    exit 2
  fi
else
  echo "  · note: notarytool inspects the app inside the disk image; an ad-hoc payload is rejected by Apple." >&2
fi

echo "→ submitting $TARGET"
xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait

echo "→ stapling"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

echo "→ Gatekeeper assessment"
spctl --assess --type "$ASSESS_TYPE" --verbose=4 "$TARGET"
echo "✓ notarized, stapled and accepted by Gatekeeper"
