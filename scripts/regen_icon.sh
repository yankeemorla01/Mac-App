#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

# Compila el renderer si hace falta
RENDERER="$SCRIPT_DIR/render_icon"
if [ ! -x "$RENDERER" ]; then
    swiftc -O -framework Cocoa -o "$RENDERER" "$SCRIPT_DIR/render_icon.swift"
fi

ICONSET="Resources/AppIcon.iconset"
SVG="Resources/icon.svg"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for sz in 16 32 64 128 256 512 1024; do
    "$RENDERER" "$SVG" $sz "$ICONSET/icon_${sz}x${sz}.png"
done
cp "$ICONSET/icon_32x32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Regenerado Resources/AppIcon.icns"
