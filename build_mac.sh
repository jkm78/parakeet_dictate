#!/bin/bash
# ==========================================================================
#  Build ParakeetDictate.app on macOS  (run this ON a Mac)
#  Produces dist/ParakeetDictate.app (+ dist/ParakeetDictate-mac-<arch>.zip)
#
#  Builds for the architecture of the Mac it runs on (Intel or Apple Silicon).
#
#  Needs Python 3.10+ with Tk 8.6+. Apple's /usr/bin/python3 ships Tk 8.5,
#  which is broken on modern macOS, so the script prefers `uv` (it fetches a
#  standalone Python 3.12 with no admin rights). Install uv once with:
#      curl -LsSf https://astral.sh/uv/install.sh | sh
#  or point PYTHON at a python.org / Homebrew python3.12 instead:
#      PYTHON=/usr/local/bin/python3.12 ./build_mac.sh
# ==========================================================================
set -euo pipefail
cd "$(dirname "$0")"

APP=ParakeetDictate
VENV=.venv-mac
VERSION=$(sed -n "s/.*StringStruct('ProductVersion', '\([0-9.]*\)').*/\1/p" version.txt | head -1)
VERSION=${VERSION%.0}          # 1.0.0.0 -> 1.0.0
ARCH=$(uname -m)

# 0) Quit a running copy so its bundle can be replaced.
pkill -x "$APP" 2>/dev/null || true

# 1) Virtual env (only created if missing).
if [ ! -x "$VENV/bin/python" ]; then
  if [ -n "${PYTHON:-}" ]; then
    "$PYTHON" -m venv "$VENV"
  elif command -v uv >/dev/null || [ -x "$HOME/.local/bin/uv" ]; then
    UV=$(command -v uv || echo "$HOME/.local/bin/uv")
    "$UV" venv --python 3.12 --seed "$VENV"
  else
    echo "[!] Need uv or PYTHON=/path/to/python3.12 (see header of this script)."
    exit 1
  fi
fi
PY="$VENV/bin/python"
"$PY" - <<'EOF'
import sys, tkinter
assert sys.version_info >= (3, 10), "Python 3.10+ required"
assert tkinter.TkVersion >= 8.6, f"Tk {tkinter.TkVersion} is too old (need 8.6+)"
EOF

# 2) Dependencies + PyInstaller (pinned to match build.bat / CI).
#    Pillow lets PyInstaller convert parakeet.ico into the .icns app icon.
if command -v uv >/dev/null || [ -x "$HOME/.local/bin/uv" ]; then
  UV=$(command -v uv || echo "$HOME/.local/bin/uv")
  "$UV" pip install --python "$PY" -r requirements.txt pyinstaller==6.21.0 pillow
else
  "$PY" -m pip install --upgrade pip
  "$PY" -m pip install -r requirements.txt pyinstaller==6.21.0 pillow
fi

# 2b) Sanity-check the pure-Python formatting/postprocess/VAD logic.
"$PY" test_formatting.py
"$PY" test_vad.py

# 3) Build. Clean stale output first so old artifacts never mix in.
rm -rf build "dist/$APP" "dist/$APP.app" "$APP.spec"
"$PY" -m PyInstaller --noconfirm --windowed --name "$APP" \
  --icon parakeet.ico \
  --osx-bundle-identifier org.parakeetdictate.app \
  --collect-all onnxruntime \
  --collect-all onnx_asr \
  --collect-submodules sounddevice \
  --hidden-import vad \
  --hidden-import keys \
  parakeet_dictate.py

# 4) Info.plist: the microphone prompt text (without it macOS silently feeds
#    the app silence), version, and dark-mode support. Then re-sign, since
#    editing the plist invalidates PyInstaller's signature.
PLIST="dist/$APP.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'Parakeet Dictate records your voice while the dictation key is held and transcribes it on this Mac. Audio never leaves the computer.'" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSRequiresAquaSystemAppearance bool false" "$PLIST" 2>/dev/null || true
# Minimum macOS = the newest "minos" of any bundled binary (onnxruntime's
# wheel is usually the strictest), so older Macs get a clear "requires macOS X"
# message instead of a crash at model load.
MINOS=$(find "dist/$APP.app" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 \
  | xargs -0 -n1 vtool -show-build 2>/dev/null | awk '/minos/{print $2}' \
  | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
MINOS=${MINOS:-11.0}
echo "[plist] LSMinimumSystemVersion = $MINOS"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $MINOS" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MINOS" "$PLIST"

# 4b) Sign with a stable local certificate (see mac_signing.sh) so macOS keeps
#     the Input Monitoring / Accessibility grants across rebuilds. Falls back
#     to ad-hoc signing (grants then reset on every rebuild) if that fails.
#     Set ADHOC=1 to skip it.
if [ "${ADHOC:-0}" != "1" ] && ./mac_signing.sh "dist/$APP.app"; then
  :
else
  echo "[sign] using ad-hoc signature (permissions reset on each rebuild)"
  codesign --force --deep --sign - "dist/$APP.app"
  codesign --verify --deep "dist/$APP.app"
fi

# 5) Zip for distribution (ditto keeps the bundle's symlinks/xattrs intact).
ZIP="dist/$APP-v$VERSION-mac-$ARCH.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "dist/$APP.app" "$ZIP"

cat <<EOF

============================================================
 Done:  dist/$APP.app
        $ZIP
 First launch downloads the model (~640 MB) once, then it
 runs fully offline. macOS will ask for Microphone, Input
 Monitoring and Accessibility permission on first run.
 Not notarized (local signature only): on another Mac,
 right-click the app > Open the first time.
============================================================
EOF
