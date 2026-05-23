#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

APP_NAME="ClipShot"
APP_DIR="build/$APP_NAME.app"

# Identidad de firma: Developer ID Application. Si no está disponible,
# cae a ad-hoc para builds de desarrollo locales.
SIGN_IDENTITY="${CLIPSHOT_SIGN_IDENTITY:-Developer ID Application: Jean Carlos Morla Genao (EC9VSP9V96)}"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo "Compilando..."
swiftc -O \
    -target arm64-apple-macosx13.0 \
    -framework Cocoa \
    -framework ServiceManagement \
    -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    src/main.swift

if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "Firmando con Developer ID + hardened runtime + timestamp..."
    codesign --force \
             --options runtime \
             --timestamp \
             --sign "$SIGN_IDENTITY" \
             "$APP_DIR"
    echo "Verificando firma..."
    codesign --verify --deep --strict --verbose=2 "$APP_DIR"
else
    echo "⚠️  Cert Developer ID no disponible, usando firma ad-hoc (solo dev local)."
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "Listo: $ROOT/$APP_DIR"
