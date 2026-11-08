#!/bin/bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="TTMigrate"
ENTITLEMENTS="$ROOT/TTMigrate/Resources/TTMigrate.entitlements"

mkdir -p "$DIST"
rm -rf "$DIST/Payload" "$DIST/${APP_NAME}.tipa" "$DIST/${APP_NAME}.ipa"

APP_PATH="$(find "$ROOT/build/Build/Products" -type d -name "${APP_NAME}.app" | head -n 1 || true)"
if [[ -z "${APP_PATH}" ]]; then
  APP_PATH="$(find "$ROOT/build" -type d -name "${APP_NAME}.app" | head -n 1 || true)"
fi
if [[ -z "${APP_PATH}" ]]; then
  echo "ERROR: ${APP_NAME}.app not found under build/"
  find "$ROOT/build" -maxdepth 5 -type d -name "*.app" || true
  exit 1
fi

echo "Using app: $APP_PATH"

if ! command -v ldid >/dev/null 2>&1; then
  echo "ERROR: ldid is required to embed entitlements for TrollStore"
  exit 1
fi
echo "Signing with entitlements: $ENTITLEMENTS"
ldid -S"$ENTITLEMENTS" "$APP_PATH/${APP_NAME}"
ldid -e "$APP_PATH/${APP_NAME}" | head -n 40

mkdir -p "$DIST/Payload"
cp -R "$APP_PATH" "$DIST/Payload/"
(
  cd "$DIST"
  zip -qr "${APP_NAME}.tipa" Payload
  cp "${APP_NAME}.tipa" "${APP_NAME}.ipa"
)
rm -rf "$DIST/Payload"

ls -lh "$DIST/${APP_NAME}.tipa"
echo "Packaged: $DIST/${APP_NAME}.tipa"
