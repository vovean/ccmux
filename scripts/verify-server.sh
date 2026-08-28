#!/usr/bin/env bash
# Starts a real ccmuxd with a real certificate and drives it with the real Mac client.
#
# The fixtures in server/testdata/wire pin the JSON shapes; this covers what sits between
# the two implementations — TLS pinning against an actual certificate, the basic-auth
# header, URL construction, HTTP/2 negotiation, and the client's error mapping. ccmuxd is
# a separate Go program, so none of that is checked by either compiler.
#
#   ./scripts/verify-server.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
PORT="${CCMUXD_VERIFY_PORT:-28500}"
trap 'kill "${SERVER_PID:-0}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

cd "$WORK"
mkdir -p certs data

# The same shape install-ccmuxd.sh produces: self-signed, both spellings as SANs.
openssl req -x509 -newkey rsa:2048 -sha256 -days 2 -nodes \
  -keyout certs/key.pem -out certs/cert.pem -subj "/CN=ccmuxd" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1

PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
printf 'ccmux:%s\n' \
  "$(printf '%s' "$PASSWORD" | openssl dgst -sha256 -hex | awk '{print $NF}')" > data/auth
chmod 600 data/auth

# The pin is SHA-256 over the DER — the same bytes the client hashes.
FINGERPRINT="$(openssl x509 -in certs/cert.pem -outform DER \
  | shasum -a 256 | cut -d' ' -f1)"

echo "verify-server: building ccmuxd"
( cd "$ROOT/server" && go build -o "$WORK/ccmuxd" . )

echo "verify-server: starting on 127.0.0.1:$PORT"
"$WORK/ccmuxd" --data-dir "$WORK/data" --cert "$WORK/certs/cert.pem" \
  --key "$WORK/certs/key.pem" --host 127.0.0.1 --port "$PORT" > "$WORK/log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if grep -q "listening" "$WORK/log" 2>/dev/null; then break; fi
  sleep 0.1
done
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "verify-server: the server exited immediately" >&2
  cat "$WORK/log" >&2
  exit 1
fi

echo "verify-server: driving it with the real Swift client"
cd "$ROOT"
CCMUXD_URL="https://127.0.0.1:$PORT" \
CCMUXD_PASSWORD="$PASSWORD" \
CCMUXD_FINGERPRINT="$FINGERPRINT" \
  make test

echo
echo "verify-server: server log"
sed 's/^/  /' "$WORK/log"
