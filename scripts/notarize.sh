#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

APP="build/ClipShot.app"
ZIP="build/ClipShot-notarize.zip"
PROFILE="${CLIPSHOT_NOTARY_PROFILE:-NOTARY}"

if [ ! -d "$APP" ]; then
    echo "No existe $APP. Corre primero: scripts/build.sh"
    exit 1
fi

# Verifica que la firma sea con Developer ID, no ad-hoc
echo "Verificando que la firma sea Developer ID..."
SIG_INFO="$(codesign --display --verbose=2 "$APP" 2>&1 || true)"
if ! echo "$SIG_INFO" | grep -q "Developer ID Application"; then
    echo "❌ La app no está firmada con Developer ID. Re-corre scripts/build.sh."
    echo "Output de codesign:"
    echo "$SIG_INFO" | head -10
    exit 1
fi

echo "Empaquetando para notarización..."
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Enviando a Apple Notary Service (esto tarda 1-5 min)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapler — adjuntando ticket al .app..."
xcrun stapler staple "$APP"

echo "Verificando con Gatekeeper..."
spctl --assess --type execute --verbose "$APP" && echo "✅ Gatekeeper acepta la app."

echo "Limpiando zip temporal..."
rm -f "$ZIP"

echo ""
echo "✅ App notarizada y stapled: $ROOT/$APP"
echo "   Puedes distribuirla directamente; Gatekeeper la abrirá sin advertencias."
