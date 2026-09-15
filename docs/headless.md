# The Linux agent — Claude Code in print mode on a pool of subscriptions

`ccmux agent` is a daemon for a Linux box. It does what the Mac app does, minus the
window: an application runs `ccmux run -- -p "…"`, the agent picks a subscription,
seeds the credential that run authenticates as, proxies its traffic, moves it to another
account when one refuses, and reports what it spent so the box appears on the Mac's
Sessions and Stats pages alongside the laptops.

It is a second Go module at `agent/`, importing ccmuxd's wire contract through a
`replace`. ccmuxd is unchanged: every route the agent uses already existed.

## Why a daemon and not a wrapper

A wrapper around each `claude -p` invocation would be simpler, and it was the first
design. Two things killed it.

A session report to ccmuxd **replaces** that machine's whole list, and a machine is
limited to 128 sessions with 32 machines in the fleet. Independent wrapper processes on
one box would overwrite each other's reports every twenty seconds, or, with a machine id
each, blow the fleet cap in an afternoon. One daemon is one reporter.

And the usage ledger only hands over a minute **after it has ended** — that immutability
is what lets the server upsert a re-send instead of adding it twice. A wrapper that exits
mid-minute has to either break the rule or lose the tail of every run. A daemon outlives
the runs, so the rule holds untouched.

## How a run works

```
application ──exec──▶ ccmux run [--model M] -- -p "…"
                          │  unix socket, /run/ccmux/control.sock
                          ▼
                    ccmux agent (systemd)
                      ├─ picks an account, draws a token from ccmuxd
                      ├─ writes ns/<session>/.credentials.json
                      ├─ binds a proxy on a port in 18000-18999
                      └─ hands the shim {namespaceDir, port}
                          │
      shim sets CLAUDE_SECURESTORAGE_CONFIG_DIR, ANTHROPIC_BASE_URL,
      _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL, CCMUX_SESSION_ID, then execs claude
                          │
                    claude ──▶ 127.0.0.1:<port> ──▶ api.anthropic.com
```

The mechanism is the Mac's, verified against Claude Code 2.1.272 on Linux:

- `CLAUDE_SECURESTORAGE_CONFIG_DIR` makes Claude Code read its credential from
  `<that dir>/.credentials.json` rather than a keychain. It watches that file's
  modification time, so rewriting it on renewal keeps a long run alive.
- The seeded credential carries **no refresh token**. ccmuxd is the sole holder of every
  lineage; the box only ever gets short-lived access tokens.
- The proxy replaces the credential on every request, which is what makes mid-run
  failover possible — Claude Code resolves its own credential once at startup and never
  re-reads it for a request already in flight.
- An **API-key** account is seeded with a placeholder that authenticates nothing
  (`ccmux-api-key-session`), because Claude Code refuses to start without a credential.
  The real key only ever appears in the proxy's `x-api-key` header.
- The shim `exec`s rather than spawning, so the pid the agent was told about is claude's
  own — which is what it checks to know the run is still alive.

A useful consequence of the proxy owning authentication: a seeded credential that has
already expired is not fatal. Claude Code sends it regardless, and the proxy replaces the
header on the way out. Measured on Linux with a token ten minutes past its expiry: the
run completed normally. So a failed renewal degrades rather than killing the run.

## Failover, and the refusal an application can act on

When a response comes back 429 or carries `anthropic-ratelimit-unified-status: rejected`,
the proxy picks another eligible account and replays the same request. Claude Code never
sees it. Each account is tried at most once per request.

When nothing can serve it, the refusal goes through untouched except for
`anthropic-ratelimit-unified-reset`, which is **shortened** to the moment some account
frees up. Only ever shortened: our view of a per-model weekly window can be stale, and
writing "now" over a correct far-future reset would loop Claude Code through every
account on the box.

Before a run even starts, the agent checks the pool. If nothing can serve the model,
`ccmux run` exits **75** (`EX_TEMPFAIL`) and prints one JSON line to stderr:

```json
{"error":"no account can serve claude-opus-5 until 2026-09-15T14:00:00Z","retryAfter":"2026-09-15T14:00:00Z"}
```

That is the contract an application should queue on. Anything else non-zero is a real
failure.

## What decides which account

Ported from the Mac, and kept honest by cross-language vectors (below):

- Eligible only with headroom on **every** window that gates the model: the 5-hour
  window, the weekly-all window, and that model's own weekly window when the plan
  reports one. A weekly window for a *different* model never gates — a spent Fable week
  does not stop an Opus request.
- Ordered **least remaining first**, on the weekly window only. One subscription is
  drained before the next is started on, because three half-used subscriptions at the end
  of the week is wasted quota. The 5-hour window refills all day, so ranking on it would
  reshuffle the order for nothing.
- An account with no usage data is eligible and sorts mid-pack.

One deliberate divergence: the Mac breaks a headroom tie on a per-machine account
priority, which does not cross the wire. The agent breaks it on the label and then the
id, so two Linux boxes agree with each other even though they cannot agree with a Mac.
The vector generator refuses to write a tie for exactly this reason.

## Session identity across a move

`SeededAccountID` is whose credential is in the namespace; `AccountID` is who serves the
requests. A **rotation** (failover) moves only the latter. An **explicit** move
(`ccmux assign`) moves both.

The reason is on the Mac too: Claude Code reads the seeded credential to decide its
organisation, an organisation mandates managed plugins, and crossing that boundary
mid-session makes a plugin that never loaded suddenly required — which blocks every model
switch after it. A `-p` run cannot switch models, so it cannot hit the gate, but the rule
costs nothing and keeps the identity honest on the Mac's pages.

## Installing

```bash
make ccmux-linux                          # dist/ccmux-linux-amd64, static, ~7 MB
tar cz dist/ccmux-linux-amd64 scripts/install-ccmux-agent.sh agent/deploy \
  | ssh root@box 'mkdir -p /tmp/ccmux && tar xz -C /tmp/ccmux'
ssh root@box '/tmp/ccmux/scripts/install-ccmux-agent.sh /tmp/ccmux/dist/ccmux-linux-amd64'
```

Then edit `/etc/ccmux/agent.yaml` (see `agent/deploy/agent.yaml.example`), and:

```bash
systemctl enable --now ccmux-agent
sudo -u ccmux ccmux status
```

Settings come from the YAML file, then the environment, then flags, in that order. The
password may be inline (the file must then be mode 0600), in a `password_file`, or
supplied by systemd's `LoadCredential=ccmux-password`. ccmuxd is self-signed, so
`server.pin` — the SHA-256 of its leaf certificate — is the whole of the trust decision
and the agent refuses to start over https without one.

## What runs as whom

The agent runs as the **same Unix user** as the application that calls `ccmux run`. The
control socket hands out sessions that decide which subscription work bills to, so its
guard is that only that user can reach it: a 0700 directory, a 0600 socket, and a
`SO_PEERCRED` check on Linux. A box hosting applications under several users needs a
different arrangement and does not have one yet.

The box holds no refresh tokens. It holds the ccmuxd password, which draws an access
token for any account — so it is exactly as trusted as a Mac in the fleet, no more.

## Commands

| Command | What it does |
|---|---|
| `ccmux agent` | The daemon. systemd runs this. |
| `ccmux run [--model M] [--account A] [--name N] [-- claude-args]` | Start a session and become claude. Unrecognised arguments go to claude, so `ccmux run -p "hi"` works without a terminator. |
| `ccmux status [--json]` | Accounts, their windows, and the live sessions. |
| `ccmux assign <session> <account>` | Move a running session, identity included. |
| `ccmux end <session>` | End a session the agent still believes is live. |

## Keeping the two implementations honest

The ranking and usage-folding rules exist twice, in Go here and in Swift on the Mac.
Nothing either compiler does would notice them drifting apart — it would surface as a
Linux box draining a different subscription from the laptops beside it.

So `agent/internal/rules/vectors_test.go` writes its answers to `agent/testdata/rules/`,
and `Tests/CCMuxKitTests/RuleVectorTests.swift` decodes them and asserts the Swift side
agrees. This is the same mechanism `server/testdata/wire` already uses for the JSON
shapes.

When a rule changes:

```bash
cd agent && UPDATE_FIXTURES=1 go test ./internal/rules/
make test        # and check the Swift side still agrees
```

## Development

```bash
make build-agent   # go build + go vet
make test-agent    # go test -race
make ccmux-linux   # the shipping binary
```

`cmd/ccmux/e2e_test.go` builds the real binary and drives the whole chain — real agent,
real control socket, real proxy — against a fake ccmuxd and a shell script standing in
for claude. It is what proves the credential is actually replaced on the way out rather
than echoed back.

## Limits worth knowing

1. **The agent is one reporter per box.** Do not run two against one ccmuxd machine id.
2. **Ranking is still per box.** A Mac and a Linux agent both pick the account with the
   least left and will drain it together, exactly as two Macs already do.
3. **A request larger than 32 MB is forwarded without being held**, so it cannot be
   replayed on another account. It loses the retry, not the request.
4. **An idle session still holds its port** until its process exits.
5. **Busy or idle is inferred from traffic**, not read from Claude Code. It writes a
   `~/.claude/sessions/<pid>.json` while a print-mode run is alive, but the shape is
   undocumented and inconsistent — measured on 2.1.272, the Linux file carries `status`
   and a freshly started macOS one does not. A run counts as busy if its proxy has
   carried a request in the last 90 seconds.
