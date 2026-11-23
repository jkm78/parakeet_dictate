#!/bin/bash
# ==========================================================================
#  Stable local code signing for the macOS build.
#
#  Why: macOS ties Input Monitoring / Accessibility grants to the app's code
#  signature. An ad-hoc signature changes on every build, so every rebuild
#  silently loses those grants (the hotkey then only works while the app's own
#  window is focused). Signing every build with the SAME self-signed
#  certificate keeps the grants across rebuilds.
#
#  The certificate lives in its own keychain (not your login keychain) under
#  ~/Library/Application Support/ParakeetDictate/signing, protected by a random
#  password stored next to it with owner-only permissions, so signing never
#  prompts. It is only trusted by this Mac's privacy settings; it is not an
#  Apple Developer ID and does not make the app notarized for other Macs.
#
#  Usage: mac_signing.sh <path/to/App.app>
#  Delete the signing folder to start over (then re-grant permissions once).
# ==========================================================================
set -euo pipefail

APP_PATH="$1"
ID_NAME="Parakeet Dictate Local Signing"
DIR="$HOME/Library/Application Support/ParakeetDictate/signing"
KC="$DIR/signing.keychain-db"
PASSF="$DIR/keychain-password"

# The user's keychain search list, captured so it can be restored exactly.
read_search_list() {
  SEARCH=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
    [ -n "$line" ] && SEARCH+=("$line")
  done < <(security list-keychains -d user)
}
restore_search_list() {
  if [ ${#SEARCH[@]} -gt 0 ]; then
    security list-keychains -d user -s "${SEARCH[@]}"
  fi
}
read_search_list

if [ ! -f "$KC" ] || [ ! -f "$PASSF" ]; then
  echo "[sign] creating local signing identity '$ID_NAME' (one time)"
  rm -f "$KC"
  mkdir -p "$DIR"
  chmod 700 "$DIR"
  (umask 077; /usr/bin/openssl rand -hex 24 > "$PASSF")
  PW=$(cat "$PASSF")
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $ID_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$ID_NAME" -out "$TMP/id.p12" -passout "pass:$PW"

  # `security create-keychain` adds the new keychain to the user's search
  # list; put the list back exactly as it was.
  security create-keychain -p "$PW" "$KC"
  restore_search_list
  security set-keychain-settings "$KC"          # no auto-lock timeout
  security unlock-keychain -p "$PW" "$KC"
  security import "$TMP/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
  # Let codesign use the key without a GUI "allow access" prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
fi

PW=$(cat "$PASSF")
security unlock-keychain -p "$PW" "$KC"
# codesign only finds private keys in keychains on the search list, so add
# ours for the duration of the signing step and always restore the original.
trap 'restore_search_list; rm -rf "${TMP:-}"' EXIT
security list-keychains -d user -s "${SEARCH[@]}" "$KC"
codesign --force --deep --keychain "$KC" --sign "$ID_NAME" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
echo "[sign] signed with '$ID_NAME'"
