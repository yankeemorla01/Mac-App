#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

APP="build/ClipShot.app"
DEST="/Applications/ClipShot.app"

if [ ! -d "$APP" ]; then
    echo "No existe $APP. Corre primero: scripts/build.sh"
    exit 1
fi

# Cierra la versión que está corriendo
pkill -f "MacOS/ClipShot" 2>/dev/null || true
sleep 0.5

rm -rf "$DEST"
cp -R "$APP" "$DEST"
# Si la app ya está firmada con Developer ID (build de release), NO la re-firmamos
# para no romper la notarización. Solo firmamos ad-hoc si la fuente era ad-hoc.
SIG_INFO="$(codesign --display --verbose=2 "$DEST" 2>&1 || true)"
if echo "$SIG_INFO" | grep -q "Developer ID Application"; then
    echo "App con Developer ID — preservando firma original."
else
    echo "App sin Developer ID — aplicando firma ad-hoc local."
    codesign --force --deep --sign - "$DEST"
fi
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

open "$DEST"
echo "Instalado en $DEST y abierto."
