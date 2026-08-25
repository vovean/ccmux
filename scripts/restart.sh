#!/bin/zsh
# Restarts ccmux without losing live sessions.
#
# Three things a plain `pkill; sleep 1; open` gets wrong: it does not wait for the app
# to actually exit, it does not check the sessions came back, and it says nothing when
# one did not. Every live session's proxy port is baked into that session's
# ANTHROPIC_BASE_URL, so a port that fails to rebind is a session that cannot make a
# request until it does.
set -euo pipefail
# EPOCHREALTIME lives in a module that only an interactive zsh loads for you.
zmodload zsh/datetime

APP=${CCMUX_APP:-/Applications/ccmux.app}
STATE="$HOME/Library/Application Support/ccmux/sessions.json"
PATTERN="ccmux.app/Contents/MacOS/ccmux"
EXIT_TIMEOUT=20
BIND_TIMEOUT=30

[[ -d "$APP" ]] || { print -r -- "restart: no app at $APP" >&2; exit 1 }

# Comes back without popping a window, for a restart you do not want to look at.
if [[ "${1:-}" == "--headless" ]]; then
  : > "$HOME/Library/Application Support/ccmux/.headless"
fi

# Ports of sessions whose claude process is still alive — the ones that have to come
# back. A record for a dead process is reaped at launch and is not expected to rebind.
expected=$(/usr/bin/python3 - "$STATE" <<'PY'
import json, os, sys
try:
    rows = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for r in rows if isinstance(rows, list) else rows.values():
    try:
        os.kill(int(r["pid"]), 0)
    except Exception:
        continue
    print(r["port"], r["id"][:8], r.get("cwd", ""))
PY
)
want=(${(f)expected})
print -r -- "restart: ${#want} live session(s) to preserve"

# Every path out of this script from here on must leave the app running: between the
# kill and the relaunch every live session has no proxy at all.
#
# The trap alone is not enough. A `set -u` violation makes zsh exit without running
# EXIT, TRAPEXIT or zshexit — measured, not assumed — which is exactly how an early
# version of this script left the app dead. So a detached watchdog goes first: it
# outlives this shell being killed outright, and no-ops when the app is already back.
relaunched=0
relaunch() {
  (( relaunched )) && return
  relaunched=1
  open -g "$APP"
}
( sleep $((EXIT_TIMEOUT + 10))
  pgrep -f "$PATTERN" >/dev/null 2>&1 || open -g "$APP" ) &!
trap relaunch EXIT INT TERM

# Timed from the kill, not from the relaunch: the app cancels its listeners as soon as
# SIGTERM lands, so new connections are refused for the whole drain too.
down=$EPOCHREALTIME
running=(${(f)"$(pgrep -f "$PATTERN" || true)"})
running=(${running:#})
if (( ${#running} )); then
  for pid in $running; do kill -TERM "$pid" 2>/dev/null || true; done
  print -rn -- "restart: draining ${(j:, :)running} "
  for i in {1..$((EXIT_TIMEOUT * 10))}; do
    alive=()
    for pid in $running; do kill -0 "$pid" 2>/dev/null && alive+=("$pid"); done
    (( ${#alive} )) || break
    sleep 0.1
    (( i % 10 == 0 )) && print -rn -- "."
  done
  if (( ${#alive} )); then
    # SIGTERM is caught and drained by the app; reaching this means it is wedged, and
    # a live session is better served by a hard restart than by a hung process.
    print -r -- " did not exit in ${EXIT_TIMEOUT}s, forcing"
    for pid in $alive; do kill -9 "$pid" 2>/dev/null || true; done
    sleep 0.5
  else
    print -r -- " exited cleanly"
  fi
else
  print -r -- "restart: not running"
fi

relaunch

# `-c ccmux` matters: without it any process listening on a session's port passes the
# check, including whatever took the port in the failure this exists to catch.
listening() {
  lsof -nP -iTCP -sTCP:LISTEN -a -c ccmux 2>/dev/null | awk '{print $9}' | sed 's/.*://'
}

missing=()
for i in {1..$((BIND_TIMEOUT * 5))}; do
  bound=("${(@f)$(listening)}")
  missing=()
  for row in $want; do
    port=${row%% *}
    (( ${bound[(I)$port]} )) || missing+=("$row")
  done
  (( ${#missing} == 0 )) && break
  sleep 0.2
done

gap=$(printf '%.1f' $((EPOCHREALTIME - down)))
if (( ${#missing} == 0 )); then
  print -r -- "restart: all ${#want} session(s) back, ${gap}s not accepting"
else
  print -r -- "restart: ${gap}s elapsed, ${#missing} session(s) still unbound:" >&2
  for row in $missing; do print -r -- "  port ${row}" >&2; done
  print -r -- "ccmux keeps retrying these every 5s; they are parked, not lost." >&2
  exit 2
fi
