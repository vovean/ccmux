# `ccmux` — the Linux CLI

Run Claude Code non-interactively across a pool of Claude subscriptions, from an
application, on a server.

Your program execs `ccmux run` instead of `claude`. A daemon on the box chooses which
subscription the run bills to, moves it to another when one is exhausted, and tells you
when to come back if none is free. Claude Code itself behaves exactly as it would
unwrapped.

For how it works and why, see [../docs/headless.md](../docs/headless.md). This file is
the interface: what to call, what comes back, and what to do about it.

---

## The shortest useful example

```bash
ccmux run -- -p "Summarise CHANGELOG.md" --output-format json
```

Everything after `--` is Claude Code's own argument list. `ccmux` supplies the executable,
so do not repeat `claude`. The process is **replaced** by Claude Code, so its stdout,
stderr and exit code are Claude Code's, unchanged.

The one line ccmux writes itself goes to stderr before the exec, and names the account it
chose:

```
ccmux: Work · claude-opus-5 · port 18104
```

---

## The contract your program depends on

Three things, and nothing else, are worth building on.

### 1. Exit code 75 means "not now, try later"

Every subscription in the pool is spent. Claude Code **was never started**, so nothing was
billed and nothing was half-done.

```
$ ccmux run --model claude-opus-5 -- -p "…"
{"error":"no account can serve claude-opus-5 until 2026-09-15T13:11:52Z","retryAfter":"2026-09-15T13:11:52Z"}
ccmux: no account can serve claude-opus-5 until 2026-09-15T13:11:52Z
exit 75
```

The first stderr line is JSON, on one line, for you to parse. `retryAfter` is RFC 3339 UTC
and is **absent** when nothing in the pool has a known reset — treat that as "wait a while
and ask again", not "never".

75 is `EX_TEMPFAIL`. Requeue the work; do not treat it as a failure of the task.

### 2. Every other non-zero exit is ordinary

- **1** — ccmux could not start the run: the daemon is not listening, the settings are
  wrong, ccmuxd is unreachable, a flag needs a value, no account has a usable credential.
  The reason is one line on stderr prefixed `ccmux:`.
- **2** — an unknown command, or none at all. The usage text goes to stderr.
- **anything else** — Claude Code's own exit code. ccmux is out of the picture by then.

### 3. Rate limits are not your problem

A 429 from Anthropic is retried on another subscription before Claude Code sees it. Your
run does not fail, does not restart, and does not need to know. If nothing can serve it
mid-run, the refusal reaches Claude Code with its retry time rewritten to the moment some
account frees up, so its own waiting logic does something sensible.

---

## Commands

### `ccmux run [flags] [-- claude-args]`

Starts a session and becomes Claude Code.

| Flag | Meaning |
|---|---|
| `--model <id>` | The model this run will use. Passed to Claude Code **and** used to choose the account, so the subscription is picked against the weekly window the request will actually consume. A `--model` you pass after `--` wins. |
| `--account <name>` | Start on this subscription instead of ranking — its id, label or email. Still refused if that account cannot serve the model or is not used on this box. A refusal later in the run can still move it to another account. |
| `--name <text>` | How the run is labelled on the fleet pages. Defaults to the basename of the working directory. |

Anything ccmux does not recognise goes to Claude Code, so `ccmux run -p "hi"` works
without a terminator. Use `--` when an argument would otherwise be ambiguous.

Settings flags (`--config`, `--socket`, …) work here too, and are listed below.

### `ccmux status [--json]`

Accounts, how much of each is left, and the live sessions. `--json` is the machine-readable
form:

```json
{
  "machineID": "51d041f2-…",
  "machineLabel": "build-box-1",
  "pendingUsageBuckets": 0,
  "accounts": [
    {
      "id": "…", "label": "Work", "kind": "subscription", "health": "ok",
      "sessions": 1, "usageAgeSeconds": 4,
      "windows": [{"kind": "weeklyAll", "label": "Weekly", "percent": 80}]
    }
  ],
  "sessions": [
    {
      "id": "…", "pid": 4131, "port": 18104, "accountID": "…",
      "seededAccountID": "…", "model": "claude-opus-5", "name": "api-gateway",
      "status": "busy", "requests": 12, "spendUSD": 0.0431
    }
  ]
}
```

`status` is `"busy"`, `"idle"` or `"waiting"`, inferred from whether the session's proxy
has carried a request in the last ninety seconds. `health` is `"ok"`, `"needsRelogin"` or
`"unknown"`. `percent` is how much of a window is **used**.

Useful before dispatching work:

```bash
ccmux status --json | jq -r '.accounts[] | select(.health=="ok")
  | "\(.label) \(100 - ([.windows[] | select(.kind=="weeklyAll") | .percent] | first // 0))% left"'
```

### `ccmux agent [flags]`

The daemon. systemd runs this; you should not need to.

### `ccmux assign <session> <account>` and `ccmux end <session>`

Move a running session to another subscription, or end one the daemon still believes is
alive. Both take the ids `ccmux status` prints. `assign` moves the session's identity as
well as its billing, which `ccmux` never does on its own.

### `ccmux version`

---

## Configuration

Three sources, each overriding the last: **the YAML file, then the environment, then
flags.**

| Setting | YAML | Environment | Flag |
|---|---|---|---|
| Settings file | — | `CCMUX_CONFIG` | `--config` |
| ccmuxd URL | `server.url` | `CCMUX_URL` | `--url` |
| Basic-auth user | `server.username` | `CCMUX_USERNAME` | `--username` |
| Password | `server.password` | `CCMUX_PASSWORD` | — |
| Password file | `server.password_file` | `CCMUX_PASSWORD_FILE` | `--password-file` |
| Certificate pin | `server.pin` | `CCMUX_PIN` | `--pin` |
| Plain HTTP | `server.insecure` | `CCMUX_INSECURE` | `--insecure` |
| Fleet label | `agent.label` | `CCMUX_LABEL` | `--label` |
| State directory | `agent.state_dir` | `CCMUX_STATE_DIR` | `--state-dir` |
| Control socket | `agent.socket` | `CCMUX_SOCKET` | `--socket` |
| Inference endpoint | `agent.upstream` | `CCMUX_UPSTREAM` | `--upstream` |
| The claude binary | `agent.claude_bin` | `CCMUX_CLAUDE_BIN` | `--claude-bin` |
| Report to the fleet | `agent.report_fleet` | `CCMUX_REPORT_FLEET` | `--no-report` |
| Proxy port band | `agent.port_first`, `agent.port_last` | — | — |
| Accounts never used (daemon only) | `agent.exclude_accounts` | `CCMUX_EXCLUDE_ACCOUNTS` (comma-separated) | — |

A complete file is in [deploy/agent.yaml.example](deploy/agent.yaml.example). The default
path is `/etc/ccmux/agent.yaml`.

For a client invocation you normally need none of this: `ccmux run` reads the same file
the daemon does and only needs the socket path, which the file supplies.

### The password

Three ways, and the agent refuses anything another user could read:

1. `server.password_file` — a file containing just the password, mode **0600**, owned by
   the user the agent runs as.
2. `server.password` inline — then the settings file itself must be mode 0600, which means
   it cannot also be group-readable for the daemon, so this suits a single-user box.
3. systemd `LoadCredential=ccmux-password:/etc/ccmux/password` — the unit names a file and
   systemd hands it over privately. Nothing goes in the settings file at all.

### The pin

ccmuxd serves a self-signed certificate, so `server.pin` — the SHA-256 of its leaf, in hex
— is the entire trust decision. Without one over https the agent refuses to start.

```bash
openssl s_client -connect ccmuxd.example:8443 </dev/null 2>/dev/null \
  | openssl x509 -outform der | shasum -a 256
```

---

## Using it from a program

### Shell

```bash
#!/usr/bin/env bash
set -uo pipefail          # not -e: exit 75 is an answer, not a failure

run_with_retry() {
  local prompt=$1 out err code until wait
  out=$(mktemp); err=$(mktemp)
  trap 'rm -f "$out" "$err"' RETURN

  for _ in 1 2 3; do
    ccmux run --model claude-opus-5 -- -p "$prompt" --output-format json \
      >"$out" 2>"$err"
    code=$?
    if [ "$code" -eq 0 ]; then cat "$out"; return 0; fi
    if [ "$code" -ne 75 ]; then cat "$err" >&2; return "$code"; fi

    # The pool is spent. The first stderr line says when to come back.
    until=$(head -1 "$err" | jq -r '.retryAfter // empty')
    if [ -z "$until" ]; then
      sleep 900                                   # nothing has a known reset
    else
      wait=$(( $(date -d "$until" +%s) - $(date +%s) + 5 ))
      sleep $(( wait > 5 ? wait : 5 ))
    fi
  done
  return 75
}
```

### Python

```python
import json, subprocess, time
from datetime import datetime, timezone

UNAVAILABLE = 75

def ask(prompt, model="claude-opus-5", attempts=3):
    """Returns Claude Code's JSON result, waiting out an exhausted pool."""
    for _ in range(attempts):
        done = subprocess.run(
            ["ccmux", "run", "--model", model, "--",
             "-p", prompt, "--output-format", "json"],
            capture_output=True, text=True)
        if done.returncode == 0:
            return json.loads(done.stdout)
        if done.returncode != UNAVAILABLE:
            raise RuntimeError(done.stderr.strip() or f"exit {done.returncode}")

        # The first stderr line is the machine-readable refusal.
        refusal = json.loads(done.stderr.splitlines()[0])
        retry_after = refusal.get("retryAfter")
        if not retry_after:
            time.sleep(900)             # nothing has a known reset
            continue
        when = datetime.fromisoformat(retry_after.replace("Z", "+00:00"))
        time.sleep(max(5, (when - datetime.now(timezone.utc)).total_seconds() + 5))
    raise TimeoutError("every subscription stayed exhausted")
```

### Node

```js
import { spawn } from "node:child_process";

const UNAVAILABLE = 75;

export function ask(prompt, { model = "claude-opus-5" } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn("ccmux", ["run", "--model", model, "--",
                                  "-p", prompt, "--output-format", "json"]);
    let out = "", err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => {
      if (code === 0) return resolve(JSON.parse(out));
      if (code !== UNAVAILABLE) return reject(new Error(err.trim()));
      // Not a failure: requeue for `retryAfter`.
      const { retryAfter } = JSON.parse(err.split("\n")[0]);
      reject(Object.assign(new Error("pool exhausted"), { retryAfter }));
    });
  });
}
```

---

## Keeping work off an account

`agent.exclude_accounts` lists accounts this box never sends work to: not at launch, not on
failover, and `--account` or `ccmux assign` naming one is refused. Each entry is an
account's id, label or email, or an organisation's name or uuid, matched without regard to
case, so one entry covers every seat in an organisation:

```yaml
agent:
  exclude_accounts: [Emcd]
```

Only the daemon reads it. Set it in agent.yaml or in the unit's environment; setting
`CCMUX_EXCLUDE_ACCOUNTS` for `ccmux run` does nothing. It applies to sessions started after
the agent reads it, so restart the agent after changing it. An entry that matches nothing
on the server is logged at startup. `ccmux status` marks excluded accounts with the
reason. If every account ends up excluded, `ccmux run` fails with exit 1 rather than 75,
since waiting will not help.

Separately, when the API answers `403 oauth_not_allowed_for_organization`, which is what
Claude Code shows as "Your organization has disabled Claude subscription access", the
request is replayed on another account. That account's whole organisation is then left
out of every pick until the agent restarts. Restarting is also how the organisation gets
tried again. If no other account can serve the request at that moment, the 403 reaches
Claude Code and the run fails with its own exit code, not 75. This is not remembered across
restarts, so use `exclude_accounts` for an organisation that has turned Claude Code off for
good.

## Running several at once

Each run gets its own port from `agent.port_first`–`agent.port_last`, one thousand by
default, released when the process exits. Hundreds of concurrent short runs are fine; the
band is the ceiling.

Two things worth knowing:

- **Ranking is per box.** Several runs starting at the same instant will all pick the
  most-drained eligible account, because that is what draining one subscription before
  starting the next means. Failover corrects them as they hit the limit. This is
  deliberate, and it is what the Macs already do.
- **A held request costs memory.** Each in-flight request is buffered up to 8 MB so a
  refusal can be replayed elsewhere. The shipped unit allows 512 MB; raise it before
  running many very large contexts at once.

---

## What you do not have to do

- **Rotate credentials.** The box never holds a refresh token. The daemon draws
  short-lived access tokens and rewrites each session's credential before it expires, in
  place, which Claude Code picks up on its own.
- **Track spend.** Every request is counted per minute, per session, per account, per
  model, priced, and posted to ccmuxd. It appears on the Mac's Stats page beside the
  laptops.
- **Clean up.** When a run exits, its proxy is closed and its credential is removed from
  disk. A restart of the daemon re-adopts runs that outlived it, on their original ports.
- **Handle the exhausted case mid-run.** That is what failover is for. You only handle it
  at launch, via exit 75.

---

## When something is wrong

| Symptom | Cause |
|---|---|
| `the ccmux agent is not listening on …` | The daemon is down. `systemctl status ccmux-agent`. |
| `could not read /etc/ccmux/agent.yaml: permission denied` | The settings file is not readable by the user running the command. It should be `0640 root:<agent user>`. |
| `… is mode 0644 and holds a password — chmod 600 it` | Exactly that. Or move the password into `password_file`. |
| `pin must be 64 hex characters` | No `server.pin` and the URL is https. |
| `ccmuxd's certificate is … which is not the pinned one` | The certificate was replaced, or the URL does not point at your ccmuxd. |
| `no account in the pool has a usable credential` | Every subscription needs signing in again. Do it from the Mac app. |
| `this ccmuxd does not advertise sessions or usage-series` | The server is older than the agent. Runs still work; the box will not appear on the fleet pages. |

The daemon logs to stdout, so `journalctl -u ccmux-agent -f` is the place to look. It
never logs a token or a password.

---

## Installing

From a checkout of this repository:

```bash
make ccmux-linux                          # dist/ccmux-linux-amd64, static, ~7 MB
tar cz dist/ccmux-linux-amd64 scripts/install-ccmux-agent.sh agent/deploy \
  | ssh root@box 'mkdir -p /tmp/ccmux && tar xz -C /tmp/ccmux'
ssh root@box '/tmp/ccmux/scripts/install-ccmux-agent.sh /tmp/ccmux/dist/ccmux-linux-amd64'
```

The installer reads its unit file and settings example from `agent/deploy/`, which is why
all three go over rather than just the binary.

Then edit `/etc/ccmux/agent.yaml`, and:

```bash
systemctl enable --now ccmux-agent
sudo -u ccmux ccmux status
```

The daemon runs as the **same user as your application**, because the control socket
hands out sessions that decide which subscription work bills to. `CCMUX_USER=myapp` on the
installer picks that user.

---

## Developing on it

```bash
make build-agent   # go build + go vet
make test-agent    # go test -race
make ccmux-linux   # the shipping binary
./scripts/verify-agent.sh   # both modules, both suites, both fixture sets, the binary
```

The ranking and pricing rules exist twice — here in Go and on the Mac in Swift. They are
held together by generated vectors: `internal/rules` and `internal/ledger` write
`testdata/rules/*.json`, and `Tests/CCMuxKitTests/RuleVectorTests.swift` decodes them and
asserts the Swift side agrees. After changing a rule:

```bash
cd agent && UPDATE_FIXTURES=1 go test ./internal/rules/ ./internal/ledger/
make test          # and check the Swift side still agrees
```
