#!/bin/bash
set -euo pipefail
: "${MACOS_CERTIFICATE_BASE64:?Missing Developer ID certificate}"
: "${MACOS_CERTIFICATE_PASSWORD:?Missing certificate password}"
: "${MACOS_PROFILE_BASE64:?Missing Developer ID host profile}"
SIGNING_DIR="$RUNNER_TEMP/wamc-signing"
mkdir -p "$SIGNING_DIR"
umask 077
python3 - <<'PY'
import base64, os
from pathlib import Path
root = Path(os.environ['RUNNER_TEMP']) / 'wamc-signing'
for variable, name in [('MACOS_CERTIFICATE_BASE64', 'certificate.p12'), ('MACOS_PROFILE_BASE64', 'host.provisionprofile')]:
    (root / name).write_bytes(base64.b64decode(os.environ[variable], validate=True))
if os.environ.get('MACOS_EXTENSION_PROFILE_BASE64'):
    (root / 'extension.provisionprofile').write_bytes(base64.b64decode(os.environ['MACOS_EXTENSION_PROFILE_BASE64'], validate=True))
PY
KEYCHAIN="$SIGNING_DIR/release.keychain-db"
PASSWORD="$(openssl rand -hex 32)"
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$SIGNING_DIR/certificate.p12" -P "$MACOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$PASSWORD" "$KEYCHAIN" > /dev/null
security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
{
    echo "WAMC_SIGNING_KEYCHAIN=$KEYCHAIN"
    echo "WAMC_PROVISIONING_PROFILE=$SIGNING_DIR/host.provisionprofile"
    if [[ -f "$SIGNING_DIR/extension.provisionprofile" ]]; then
        echo "WAMC_EXTENSION_PROFILE=$SIGNING_DIR/extension.provisionprofile"
    fi
} >> "$GITHUB_ENV"
