#!/bin/bash
set -euo pipefail
umask 077

if [[ $# -ne 1 || ! -d "$1/Contents" ]]; then
  echo "Usage: $0 /absolute/path/Remarc.app" >&2
  exit 1
fi
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(cd "$1" && pwd)"
python3 "$REPO_ROOT/scripts/verify-ventura-app.py" "$APP"

# Keep the identity stable across rebuilds. Private material never enters the repo.
SIGNING_DIR="$HOME/Library/Application Support/RemarcLocalSigning"
SIGNING_KEYCHAIN="$SIGNING_DIR/Remarc.keychain-db"
SIGNING_NAME="Remarc Local Development"
mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"
if [[ ! -f "$SIGNING_DIR/password" ]]; then
  /usr/bin/openssl rand -hex 32 > "$SIGNING_DIR/password"
fi
SIGNING_PASSWORD="$(cat "$SIGNING_DIR/password")"
if [[ ! -f "$SIGNING_KEYCHAIN" ]]; then
  security create-keychain -p "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN"
fi
security unlock-keychain -p "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN"

if ! security find-certificate -c "$SIGNING_NAME" "$SIGNING_KEYCHAIN" >/dev/null 2>&1; then
  CERT_TMP="$(mktemp -d)"
  trap 'rm -rf "$CERT_TMP"' EXIT
  cat > "$CERT_TMP/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = Remarc Local Development
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -config "$CERT_TMP/openssl.cnf" -keyout "$CERT_TMP/key.pem" \
    -out "$CERT_TMP/cert.pem" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -name "$SIGNING_NAME" \
    -inkey "$CERT_TMP/key.pem" -in "$CERT_TMP/cert.pem" \
    -out "$CERT_TMP/identity.p12" -passout "file:$SIGNING_DIR/password"
  security import "$CERT_TMP/identity.p12" -k "$SIGNING_KEYCHAIN" \
    -P "$SIGNING_PASSWORD" -T /usr/bin/codesign >/dev/null
fi

# Trust only this code-signing identity in the current user's trust store.
CERT_EXPORT="$(mktemp)"
security find-certificate -c "$SIGNING_NAME" -p "$SIGNING_KEYCHAIN" > "$CERT_EXPORT"
security add-trusted-cert -r trustRoot -p codeSign -k "$SIGNING_KEYCHAIN" "$CERT_EXPORT"
rm -f "$CERT_EXPORT"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null

# Ventura's codesign also needs the identity's keychain in the search list.
# Restore the user's list even if signing fails; never change the default keychain.
python3 - "$SIGNING_KEYCHAIN" "$SIGNING_NAME" "$REPO_ROOT/app/Config/Ventura.entitlements" "$APP" <<'PYTHON'
import shlex
import subprocess
import sys

keychain, name, entitlements, app = sys.argv[1:]
original = shlex.split(subprocess.check_output(["security", "list-keychains", "-d", "user"], text=True))
try:
    subprocess.run(["security", "list-keychains", "-d", "user", "-s", *dict.fromkeys([*original, keychain])], check=True)
    subprocess.run(["codesign", "--force", "--sign", name, "--keychain", keychain,
                    "--timestamp=none", "--entitlements", entitlements, app], check=True)
finally:
    subprocess.run(["security", "list-keychains", "-d", "user", "-s", *original], check=True)
PYTHON
codesign --verify --deep --strict "$APP"
echo "Locally signed: $APP"
