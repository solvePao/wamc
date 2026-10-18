#!/bin/bash
set -euo pipefail
: "${NOTARY_KEY_BASE64:?Missing App Store Connect API key for notarization}"
: "${NOTARY_KEY_ID:?Missing notarization key ID}"
: "${NOTARY_ISSUER_ID:?Missing notarization issuer ID}"
APP="$1"
DMG="$2"
TEMPORARY="$(mktemp -d)"
trap 'rm -rf "$TEMPORARY"' EXIT
umask 077
python3 - "$TEMPORARY/key.p8" <<'PY'
import base64, os, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(base64.b64decode(os.environ['NOTARY_KEY_BASE64'], validate=True))
PY
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMPORARY/WAMC.zip"
xcrun notarytool submit "$TEMPORARY/WAMC.zip" --key "$TEMPORARY/key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
WAMC_APP_DIR="$APP" WAMC_COVERAGE_VERIFIED=true bash macos/scripts/build_dmg.sh "$DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --key "$TEMPORARY/key.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
hdiutil verify "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
