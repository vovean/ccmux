#!/usr/bin/env bash
# Prepares a host to run ccmuxd: a self-signed certificate covering however you reach the
# box, a basic-auth credential, and a compose file to run it with.
#
# Host-agnostic on purpose — pass the names and addresses you will actually use:
#   ./install-ccmuxd.sh --dns ccmux.example.com --ip 203.0.113.10
#
# Run it on the server. It writes to ./ccmuxd by default and starts nothing.
set -euo pipefail

DNS_NAMES=()
IP_ADDRS=()
TARGET="$(pwd)/ccmuxd"
PORT=8443
IMAGE=ccmuxd:latest
USERNAME=ccmux

usage() {
  cat <<'EOF'
install-ccmuxd.sh — set up a ccmux account server

  --dns NAME       DNS name clients will use (repeatable)
  --ip ADDR        IP address clients will use (repeatable)
  --dir PATH       where to write config and data (default ./ccmuxd)
  --port N         port to publish (default 8443)
  --image NAME     container image to run (default ccmuxd:latest)
  --user NAME      basic-auth username (default ccmux)

At least one --dns or --ip is required: they become the certificate's SANs, and a
client that reaches the server by a name the certificate does not cover will refuse
the connection.

Build the image first, from the repository root:
  docker build -f server/Dockerfile -t ccmuxd .
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dns) DNS_NAMES+=("$2"); shift 2 ;;
    --ip) IP_ADDRS+=("$2"); shift 2 ;;
    --dir) TARGET="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --user) USERNAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install-ccmuxd: unknown flag $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ${#DNS_NAMES[@]} -eq 0 && ${#IP_ADDRS[@]} -eq 0 ]]; then
  echo "install-ccmuxd: pass at least one --dns or --ip" >&2
  exit 2
fi
command -v openssl >/dev/null || { echo "install-ccmuxd: openssl is required" >&2; exit 1; }

CERTS="$TARGET/certs"
DATA="$TARGET/data"
mkdir -p "$CERTS" "$DATA"
chmod 700 "$TARGET" "$CERTS" "$DATA"

# --- certificate -------------------------------------------------------------
# Both spellings go in as SANs so one certificate serves the DNS name and the raw
# address. A public CA will not issue for an IP, which is why this is self-signed and
# why the client pins it.
if [[ -f "$CERTS/cert.pem" ]]; then
  echo "install-ccmuxd: keeping the existing certificate at $CERTS/cert.pem"
else
  SAN=""
  for name in ${DNS_NAMES+"${DNS_NAMES[@]}"}; do SAN+="DNS:$name,"; done
  for addr in ${IP_ADDRS+"${IP_ADDRS[@]}"}; do SAN+="IP:$addr,"; done
  SAN="${SAN%,}"

  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "$CERTS/key.pem" -out "$CERTS/cert.pem" \
    -subj "/CN=ccmuxd" -addext "subjectAltName=$SAN" >/dev/null 2>&1
  chmod 600 "$CERTS/key.pem"
  chmod 644 "$CERTS/cert.pem"
  echo "install-ccmuxd: certificate written, SANs: $SAN"
fi

# --- basic auth --------------------------------------------------------------
# The file holds a SHA-256, never the password. The password is shown once, here, and
# is not recoverable afterwards — rerun with the auth file deleted to issue a new one.
if [[ -f "$DATA/auth" ]]; then
  echo "install-ccmuxd: keeping the existing credential at $DATA/auth"
  PASSWORD=""
else
  PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  HASH="$(printf '%s' "$PASSWORD" | openssl dgst -sha256 -hex | awk '{print $NF}')"
  printf '%s:%s\n' "$USERNAME" "$HASH" > "$DATA/auth"
  chmod 600 "$DATA/auth"
fi

# --- compose -----------------------------------------------------------------
# The container runs as whoever owns these files, rather than the image's own user.
# data/ is 0700 and holds every refresh lineage, so the alternative is either chowning it
# to the image's uid (needs root) or loosening it to world-readable (defeats the point).
RUN_UID="$(id -u)"
RUN_GID="$(id -g)"
if [[ "$RUN_UID" == "0" ]]; then
  echo "install-ccmuxd: WARNING — run as an ordinary user, not root; the container would" >&2
  echo "                run as root too. Re-run as a normal user for a smaller blast radius." >&2
fi

cat > "$TARGET/docker-compose.yml" <<EOF
services:
  ccmuxd:
    image: $IMAGE
    restart: unless-stopped
    user: "$RUN_UID:$RUN_GID"
    command: ["--port", "8443"]
    ports:
      - "$PORT:8443"
    volumes:
      - ./data:/var/lib/ccmuxd
      - ./certs:/etc/ccmuxd:ro
EOF

FINGERPRINT="$(openssl x509 -in "$CERTS/cert.pem" -noout -fingerprint -sha256 \
  | sed 's/.*=//')"

cat <<EOF

  Ready. From $TARGET:

    docker compose up -d

  Point ccmux at it on each Mac — Settings → Account server:

    address      ${DNS_NAMES[0]:-${IP_ADDRS[0]}}:$PORT
    username     $USERNAME
EOF
if [[ -n "$PASSWORD" ]]; then
  cat <<EOF
    password     $PASSWORD

  That password is shown once and is not stored in recoverable form. Delete
  $DATA/auth and rerun this script to issue a new one.
EOF
fi
cat <<EOF

  ccmux will ask you to confirm this certificate on first connect:

    $FINGERPRINT

  Back up $DATA — it holds every refresh lineage, sealed with master.key
  in the same directory. Losing it means signing every account in again.

EOF
