#!/usr/bin/env bash
# Installs the ccmux agent on a Linux box. Run as root.
#
# Deliberately does not write the password or the pin: both are yours to paste into
# /etc/ccmux/agent.yaml, and a script that generated them would be guessing.
set -euo pipefail

BINARY="${1:-./dist/ccmux-linux-amd64}"
USER_NAME="${CCMUX_USER:-ccmux}"

[ -f "$BINARY" ] || { echo "no binary at $BINARY — run 'make ccmux-linux' first" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run this as root" >&2; exit 1; }

if ! id "$USER_NAME" >/dev/null 2>&1; then
  # No login and no home: this account exists to own a socket and a state directory.
  useradd --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME"
  echo "created user $USER_NAME"
fi

install -m 0755 "$BINARY" /usr/local/bin/ccmux
install -d -m 0750 -o root -g "$USER_NAME" /etc/ccmux
install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" /var/lib/ccmux

if [ ! -f /etc/ccmux/agent.yaml ]; then
  # 0640 root:$USER_NAME — the agent reads it, only root writes it. Note that an inline
  # `password:` is refused on a group-readable file, which is why the example points at a
  # separate password file instead.
  install -m 0640 -o root -g "$USER_NAME" \
    "$(dirname "$0")/../agent/deploy/agent.yaml.example" /etc/ccmux/agent.yaml
  echo "wrote /etc/ccmux/agent.yaml — set server.url, server.pin and the password"
fi

install -m 0644 "$(dirname "$0")/../agent/deploy/ccmux-agent.service" \
  /etc/systemd/system/ccmux-agent.service
sed -i "s/^User=ccmux$/User=$USER_NAME/; s/^Group=ccmux$/Group=$USER_NAME/" \
  /etc/systemd/system/ccmux-agent.service
systemctl daemon-reload

cat <<NOTE

Installed. Before starting it:
  1. Edit /etc/ccmux/agent.yaml — server.url, server.pin, and the password.
  2. If you use a password file, it must be readable ONLY by its owner:
       install -m 0600 -o $USER_NAME -g $USER_NAME <file> /etc/ccmux/password
  3. systemctl enable --now ccmux-agent && systemctl status ccmux-agent
  4. sudo -u $USER_NAME ccmux status

Applications call `ccmux run -- -p "…"` as $USER_NAME. Everything after `--` is
claude's own argument list; ccmux supplies the executable.
NOTE
