#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: Arush Yadav (FJ696ZCQ56)}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-HU27CJ3DK6}"
export DEVELOPMENT_TEAM

mkdir -p "$MACOS_DIR/.build"
STAGING_DIR="$(mktemp -d "$MACOS_DIR/.build/wamc-install.XXXXXX")"
INSTALL_STAGING=""
cleanup() {
    if [[ -n "$INSTALL_STAGING" ]]; then
        if [[ ! -d /Applications/WAMC.app && -d "$INSTALL_STAGING/Previous.app" ]]; then
            mv "$INSTALL_STAGING/Previous.app" /Applications/WAMC.app
        fi
        rm -rf "$INSTALL_STAGING"
    fi
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
APP_DIR="$STAGING_DIR/WAMC.app"
WAMC_APP_OUTPUT="$APP_DIR" bash "$SCRIPT_DIR/build_bundle.sh"

echo "==> Installing validated WAMC..."
INSTALL_STAGING="$(mktemp -d /Applications/.WAMC-install.XXXXXX)"
ditto "$APP_DIR" "$INSTALL_STAGING/WAMC.app"
pkill -x WAMC || true
for ((attempt = 0; attempt < 50; attempt++)); do
    if ! pgrep -x WAMC > /dev/null; then break; fi
    sleep 0.1
done
if pgrep -x WAMC > /dev/null; then
    echo "WAMC has not exited; the installed app has not been changed." >&2
    exit 1
fi
if [[ -d /Applications/WAMC.app ]]; then
    mv /Applications/WAMC.app "$INSTALL_STAGING/Previous.app"
fi
mv "$INSTALL_STAGING/WAMC.app" /Applications/WAMC.app

echo "==> Launching updated WAMC..."
# LaunchServices can briefly retain the exited instance (error -600).
# Request a new instance and allow its bookkeeping to settle before retrying.
LAUNCHED=false
for attempt in 1 2 3; do
    if open -n /Applications/WAMC.app; then
        sleep 0.5
        if pgrep -x WAMC > /dev/null; then LAUNCHED=true; break; fi
    fi
    sleep 1
done
if ! $LAUNCHED; then
    if [[ -d "$INSTALL_STAGING/Previous.app" ]]; then
        mv /Applications/WAMC.app "$INSTALL_STAGING/Failed.app"
        mv "$INSTALL_STAGING/Previous.app" /Applications/WAMC.app
        open -n /Applications/WAMC.app || true
    fi
    echo "Launch verification failed; the previous installation was restored when available." >&2
    exit 1
fi

echo "==> Build and deployment completed successfully!"

