#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

APP_NAME="ClipShot"
APP_DIR="build/$APP_NAME.app"
SPARKLE_DIR="vendor/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.framework"

# Identidad de firma: Developer ID Application. Si no está disponible,
# cae a ad-hoc para builds de desarrollo locales.
SIGN_IDENTITY="${CLIPSHOT_SIGN_IDENTITY:-Developer ID Application: Jean Carlos Morla Genao (EC9VSP9V96)}"

if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "❌ No existe $SPARKLE_FRAMEWORK"
    echo "   Descarga Sparkle: ./scripts/setup_sparkle.sh"
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Localización: copia cada <lang>.lproj (InfoPlist.strings) al bundle. Así macOS
# muestra los diálogos de permisos en español si el Mac está en español, y en
# inglés en cualquier otro caso. La UI dentro de la app se localiza en runtime.
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP_DIR/Contents/Resources/"
done

# Copia Sparkle.framework preservando los symlinks de la estructura Versions/Current.
# `cp -R -L` los seguiría, lo que rompe la firma del framework.
echo "Embebiendo Sparkle.framework..."
cp -R "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"

echo "Compilando para arm64..."
swiftc -O \
    -target arm64-apple-macosx13.0 \
    -framework Cocoa \
    -framework ServiceManagement \
    -framework Quartz \
    -framework Vision \
    -framework Carbon \
    -F "$SPARKLE_DIR" \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "/tmp/ClipShot-arm64" \
    src/main.swift

echo "Compilando para x86_64 (Intel)..."
swiftc -O \
    -target x86_64-apple-macosx13.0 \
    -framework Cocoa \
    -framework ServiceManagement \
    -framework Quartz \
    -framework Vision \
    -framework Carbon \
    -F "$SPARKLE_DIR" \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "/tmp/ClipShot-x86_64" \
    src/main.swift

echo "Combinando arm64 + x86_64 en Universal Binary con lipo..."
lipo -create \
    "/tmp/ClipShot-arm64" \
    "/tmp/ClipShot-x86_64" \
    -output "$APP_DIR/Contents/MacOS/$APP_NAME"

rm -f /tmp/ClipShot-arm64 /tmp/ClipShot-x86_64
lipo -info "$APP_DIR/Contents/MacOS/$APP_NAME"

if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "Firmando Sparkle inside-out (XPC services → Updater.app → Autoupdate → framework)..."
    # Sparkle 2.x viene con XPC services pre-firmados por el proyecto Sparkle.
    # Para que pase notarization debemos re-firmar TODO con nuestro Developer ID
    # y con hardened runtime. Orden inside-out: lo más profundo primero.
    SP_VER_CURRENT="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/Current"

    for xpc in "$SP_VER_CURRENT/XPCServices/"*.xpc; do
        [ -d "$xpc" ] || continue
        codesign --force --options runtime --timestamp \
                 --sign "$SIGN_IDENTITY" "$xpc"
    done

    codesign --force --options runtime --timestamp \
             --sign "$SIGN_IDENTITY" "$SP_VER_CURRENT/Updater.app"

    codesign --force --options runtime --timestamp \
             --sign "$SIGN_IDENTITY" "$SP_VER_CURRENT/Autoupdate"

    codesign --force --options runtime --timestamp \
             --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/Frameworks/Sparkle.framework"

    echo "Firmando la app principal con Developer ID + hardened runtime + timestamp..."
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
