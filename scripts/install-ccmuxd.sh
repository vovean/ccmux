#!/usr/bin/env bash
# Prepares a host to run ccmuxd: a self-signed certificate covering however you reach the
# box, a basic-auth credential, and either a compose file or a systemd unit.
#
# Host-agnostic on purpose — pass the names and addresses you will actually use:
#   ./install-ccmuxd.sh --dns ccmux.example.com --ip 203.0.113.10
#   ./install-ccmuxd.sh --mode systemd --binary ./ccmuxd --ip 10.0.0.1 --bind 10.0.0.1
#
# Run it on the server. Docker mode writes to ./ccmuxd and starts nothing; systemd mode
# needs root, installs system-wide, and enables the service.
set -euo pipefail

MODE=docker
DNS_NAMES=()
IP_ADDRS=()
TARGET="$(pwd)/ccmuxd"
PORT=8443
BIND=0.0.0.0
IMAGE=ccmuxd:latest
USERNAME=ccmux
BINARY=""
# The box this was written for has 961 MB of RAM shared with the VPN machinery. A cap
# means ccmuxd can never be the reason the OOM killer reaches for something else.
MEMORY_MAX=192M

usage() {
  cat <<'EOF'
install-ccmuxd.sh — set up a ccmux account server

  --mode docker|systemd   how to run it (default docker)
  --dns NAME              DNS name clients will use (repeatable)
  --ip ADDR               IP address clients will use (repeatable)
  --port N                port to listen on (default 8443)
  --bind ADDR             address to bind (default 0.0.0.0; systemd mode only)
  --user NAME             basic-auth username (default ccmux)

docker mode:
  --dir PATH              where to write config and data (default ./ccmuxd)
  --image NAME            container image to run (default ccmuxd:latest)

systemd mode (needs root):
  --binary PATH           the ccmuxd binary to install
  --memory-max SIZE       systemd MemoryMax (default 192M)

At least one --dns or --ip is required: they become the certificate's SANs, and a
client that reaches the server by a name the certificate does not cover will refuse
the connection.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --dns) DNS_NAMES+=("$2"); shift 2 ;;
    --ip) IP_ADDRS+=("$2"); shift 2 ;;
    --dir) TARGET="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --bind) BIND="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --user) USERNAME="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --memory-max) MEMORY_MAX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install-ccmuxd: unknown flag $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MODE" in docker|systemd) ;; *)
  echo "install-ccmuxd: --mode must be docker or systemd" >&2; exit 2 ;;
esac
if [[ ${#DNS_NAMES[@]} -eq 0 && ${#IP_ADDRS[@]} -eq 0 ]]; then
  echo "install-ccmuxd: pass at least one --dns or --ip" >&2
  exit 2
fi
command -v openssl >/dev/null || { echo "install-ccmuxd: openssl is required" >&2; exit 1; }

if [[ "$MODE" == systemd ]]; then
  [[ $EUID -eq 0 ]] || { echo "install-ccmuxd: systemd mode needs root" >&2; exit 1; }
  [[ -n "$BINARY" && -f "$BINARY" ]] || {
    echo "install-ccmuxd: --binary PATH is required in systemd mode" >&2; exit 1; }
  CERTS=/etc/ccmuxd
  DATA=/var/lib/ccmuxd
else
  CERTS="$TARGET/certs"
  DATA="$TARGET/data"
fi

mkdir -p "$CERTS" "$DATA"
[[ "$MODE" == docker ]] && chmod 700 "$TARGET"
chmod 700 "$CERTS" "$DATA"

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

if [[ "$MODE" == systemd ]]; then
  # --- systemd -----------------------------------------------------------------
  id -u ccmuxd >/dev/null 2>&1 || \
    useradd --system --no-create-home --shell /usr/sbin/nologin ccmuxd
  install -m 0755 "$BINARY" /usr/local/bin/ccmuxd

  # The service runs as ccmuxd, so it needs to traverse the certificate directory to open
  # the key — a 0700 root-owned directory would fail to start with a bare "permission
  # denied" and nothing pointing at the directory rather than the file.
  chown root:ccmuxd "$CERTS"
  chmod 750 "$CERTS"
  chown root:ccmuxd "$CERTS/key.pem"
  chmod 640 "$CERTS/key.pem"
  # The sealed store and the master key are the whole prize: owned by the service, 0700,
  # readable by nothing else.
  chown -R ccmuxd:ccmuxd "$DATA"
  chmod 700 "$DATA"

  cat > /etc/systemd/system/ccmuxd.service <<EOF
[Unit]
Description=ccmux account server
Documentation=https://github.com/vovean/ccmux/blob/master/docs/server.md
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
User=ccmuxd
Group=ccmuxd
ExecStart=/usr/local/bin/ccmuxd --data-dir $DATA --cert $CERTS/cert.pem \\
  --key $CERTS/key.pem --host $BIND --port $PORT
Restart=on-failure
RestartSec=5

# It holds every refresh lineage, so it gets as little of the machine as it can work with.
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native
CapabilityBoundingSet=

# A hard ceiling, so ccmuxd can never be the reason the OOM killer reaches for whatever
# else this box is running.
MemoryMax=$MEMORY_MAX
MemoryHigh=128M

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ccmuxd >/dev/null 2>&1 || systemctl enable --now ccmuxd
  sleep 2
  systemctl --no-pager --lines=0 status ccmuxd | head -4 || true
else
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
fi

FINGERPRINT="$(openssl x509 -in "$CERTS/cert.pem" -noout -fingerprint -sha256 \
  | sed 's/.*=//')"

echo
if [[ "$MODE" == systemd ]]; then
  echo "  Running as a systemd service:  systemctl status ccmuxd"
else
  echo "  Ready. From $TARGET:  docker compose up -d"
fi
cat <<EOF

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
