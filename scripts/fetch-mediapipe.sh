#!/bin/bash
# Downloads the pinned MediaPipe 1.2.3 macOS arm64 wheel from PyPI (SHA-256 checked) and
# extracts libmediapipe.dylib into vendor/. Also fetches the face landmarker model and
# makes a test image. Everything stays inside the project folder.
set -euo pipefail
cd "$(dirname "$0")/.."
VER=1.2.3
WHEEL=mediapipe-$VER-py3-none-macosx_11_0_arm64.whl
URL=https://files.pythonhosted.org/packages/8a/31/5dcba256f3d7c02cabc834628006aa36c7b36752f1df18082e3dae6229fa/$WHEEL
SHA=077ef409d79ef274b076d47a744018af5f7487c09a1d237e9d2f707d33e39867
MODEL_URL=https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
mkdir -p .cache vendor
if [ ! -f vendor/libmediapipe.dylib ]; then
  [ -f .cache/$WHEEL ] || curl -fL --progress-bar -o .cache/$WHEEL "$URL"
  echo "$SHA  .cache/$WHEEL" | shasum -a 256 -c -
  rm -rf .cache/wheel && mkdir -p .cache/wheel && unzip -q -o .cache/$WHEEL -d .cache/wheel
  SRC=$(find .cache/wheel -name 'libmediapipe*.dylib' -o -name 'libmediapipe*.so' | head -1)
  echo "found $SRC"
  cp "$SRC" vendor/libmediapipe.dylib
  install_name_tool -id @rpath/libmediapipe.dylib vendor/libmediapipe.dylib
  # keep the wheel's own model files if present
  find .cache/wheel -name '*.task' -exec cp {} vendor/ \; 2>/dev/null || true
fi
if [ ! -f vendor/face_landmarker.task ]; then
  curl -fL --progress-bar -o vendor/face_landmarker.task "$MODEL_URL"
fi
echo "vendor ready:"; ls -la vendor
