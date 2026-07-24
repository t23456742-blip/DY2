#!/bin/bash
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP_NAME="DYSlimClean"

# CI 平铺：Resources/… ；本地嵌套：DYSlimClean/Resources/…
if [[ -f "$ROOT/Resources/DYSlimClean.entitlements" ]]; then
  ENTITLEMENTS="$ROOT/Resources/DYSlimClean.entitlements"
elif [[ -f "$ROOT/DYSlimClean/Resources/DYSlimClean.entitlements" ]]; then
  ENTITLEMENTS="$ROOT/DYSlimClean/Resources/DYSlimClean.entitlements"
else
  echo "ERROR: DYSlimClean.entitlements not found"
  ls -la "$ROOT" "$ROOT/Resources" 2>/dev/null || true
  exit 1
fi

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

MARKETING_VERSION="${MARKETING_VERSION:-14.0}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-140}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" "$APP_PATH/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${MARKETING_VERSION}" "$APP_PATH/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${CURRENT_PROJECT_VERSION}" "$APP_PATH/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${CURRENT_PROJECT_VERSION}" "$APP_PATH/Info.plist"
echo "App version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist"))"

if ! command -v ldid >/dev/null 2>&1; then
  echo "ERROR: ldid is required to embed entitlements for TrollStore"
  exit 1
fi

BIN="$APP_PATH/${APP_NAME}"
if [[ ! -f "$BIN" ]]; then
  echo "ERROR: binary not found: $BIN"
  ls -la "$APP_PATH"
  exit 1
fi

echo "Signing with entitlements: $ENTITLEMENTS"
ldid -S"$ENTITLEMENTS" "$BIN"

# tipa = ipa renamed
(
  cd "$ROOT"
  rm -rf Payload
  mkdir -p Payload
  cp -R "$APP_PATH" "Payload/${APP_NAME}.app"
  zip -qr "$DIST/${APP_NAME}.ipa" Payload
  cp "$DIST/${APP_NAME}.ipa" "$DIST/${APP_NAME}.tipa"
  rm -rf Payload
)

echo "OK: $DIST/${APP_NAME}.tipa"
ls -la "$DIST"
