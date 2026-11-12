#!/bin/bash
# Builds HeadClick.app (release) into build/, embeds libmediapipe + model, signs with the
# Apple Development identity so Camera/Accessibility grants survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${HEADCLICK_IDENTITY:-Apple Development: mohammadreza Ahmaditeshnizi (L36DR2X88W)}"
CONFIG="${CONFIG:-release}"
[ -f vendor/libmediapipe.dylib ] || ./scripts/fetch-mediapipe.sh
swift build -c "$CONFIG" --product HeadClick
BIN=$(swift build -c "$CONFIG" --show-bin-path)/HeadClick
[ -x "$BIN" ] || { echo "build failed"; exit 1; }
APP=build/HeadClick.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HeadClick"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp vendor/libmediapipe.dylib "$APP/Contents/Frameworks/"
cp vendor/face_landmarker.task Resources/test-face.jpg "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/Frameworks/libmediapipe.dylib"
codesign --force --sign "$IDENTITY" --timestamp=none --identifier com.rezaahmadi.headclick "$APP"
codesign -v --strict "$APP" && echo "codesign OK: $APP"
