#!/bin/zsh
# One-time: creates a self-signed code-signing identity in a dedicated keychain, so every build of
# Takes has the same signature and macOS keeps its screen-recording / accessibility permissions.
set -euo pipefail
NAME="Takes Local Signing"
KC="$HOME/Library/Keychains/takes-signing.keychain-db"
PASS="takes-local"

if security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  echo "Signing identity already exists in $KC"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:$PASS

[[ -f "$KC" ]] || security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
# Add to the search list without dropping existing keychains.
existing=("${(@f)$(security list-keychains -d user | sed 's/[ "]//g')}")
security list-keychains -d user -s "${existing[@]}" "$KC"
echo "Created signing identity '$NAME' in $KC"
