#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

APP="build/ClipShot.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo "1.0")"
DMG_NAME="ClipShot-$VERSION"
DMG_PATH="build/$DMG_NAME.dmg"
DMG_TMP_PATH="build/$DMG_NAME-tmp.dmg"
STAGING="build/dmg-staging"
VOLNAME="ClipShot"
SIGN_IDENTITY="${CLIPSHOT_SIGN_IDENTITY:-Developer ID Application: Jean Carlos Morla Genao (EC9VSP9V96)}"
NOTARY_PROFILE="${CLIPSHOT_NOTARY_PROFILE:-NOTARY}"

if [ ! -d "$APP" ]; then
    echo "❌ No existe $APP. Corre: make notarize"
    exit 1
fi

# Verifica que la app esté stapled (notarizada) antes de empacarla
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "⚠️  La app no tiene ticket de notarización. Recomendado: corre 'make notarize' primero."
    echo "    Continuando de todos modos en 3s... (Ctrl-C para abortar)"
    sleep 3
fi

# Por si quedó montado de un intento anterior
hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true

# Limpia staging
rm -rf "$STAGING" "$DMG_TMP_PATH" "$DMG_PATH"
mkdir -p "$STAGING"

echo "Preparando contenido del DMG..."
cp -R "$APP" "$STAGING/ClipShot.app"
ln -s /Applications "$STAGING/Applications"

# Crea DMG temporal en formato UDRW para poder ajustar la ventana
SIZE_MB=$(($(du -sm "$STAGING" | awk '{print $1}') + 40))
echo "Creando DMG temporal (~${SIZE_MB}MB)..."
hdiutil create -volname "$VOLNAME" \
               -srcfolder "$STAGING" \
               -ov \
               -fs HFS+ \
               -format UDRW \
               -size ${SIZE_MB}m \
               "$DMG_TMP_PATH"

echo "Montando para aplicar layout..."
MOUNT_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TMP_PATH")
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | grep -E '/Volumes/' | awk '{print $NF}' | head -1)
sleep 1

echo "Aplicando layout (ventana 540x360, icon size 96)..."
osascript <<EOF
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 740, 560}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set text size of theViewOptions to 13
        set position of item "ClipShot.app" of container window to {140, 180}
        set position of item "Applications" of container window to {400, 180}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
EOF

sync
sleep 1
hdiutil detach "$MOUNT_POINT" -quiet
sleep 1

echo "Comprimiendo a formato final (UDZO)..."
hdiutil convert "$DMG_TMP_PATH" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$DMG_TMP_PATH"

if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "Firmando el DMG..."
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

    echo "Notarizando el DMG (1-3 min)..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

    echo "Adjuntando ticket al DMG..."
    xcrun stapler staple "$DMG_PATH"

    echo "Verificando con Gatekeeper..."
    spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH" \
        && echo "✅ Gatekeeper acepta el DMG."
else
    echo "⚠️  Cert Developer ID no disponible — DMG sin firmar (solo dev local)."
fi

rm -rf "$STAGING"

DMG_SIZE=$(du -sh "$DMG_PATH" | awk '{print $1}')
echo ""
echo "✅ DMG listo: $ROOT/$DMG_PATH ($DMG_SIZE)"
echo "   Compártelo (Mail, AirDrop, web). Doble-click → arrastrar a Apps. Cero warnings."
