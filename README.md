# ccmux

Runs each Claude Code session on the subscription you choose, and moves a session to
another account when the one it is on runs out.

macOS 14+. SwiftPM + SwiftUI, built without Xcode.

## Why it works the way it does

Two mechanisms, both verified against the Claude Code binary rather than guessed:

**Per-session credential namespace.** `CLAUDE_SECURESTORAGE_CONFIG_DIR=<dir>` makes
Claude Code read its OAuth credential from Keychain service
`"Claude Code-credentials-" + sha256(NFC(dir))[0..8]` instead of the global
`"Claude Code-credentials"`. ccmux seeds that item, so the credential Claude Code
authenticates with really is the assigned account's — an unseeded namespace reports "Not
logged in", which is how that was confirmed. Config, history and `~/.claude/projects` stay
shared, unlike `CLAUDE_CONFIG_DIR`.

One honest caveat: only *credentials* are namespaced. The account **name** Claude Code
prints comes from `oauthAccount` in the shared `~/.claude.json`, which is whichever
account logged in last anywhere on the Mac — so `claude auth status` inside a session can
show a different email than the account actually serving it. Billing, limits and
`/usage` follow the credential and are correct; the displayed name can lie. ccmux's own
Accounts and Sessions screens are the reliable answer.

**Per-session loopback proxy.** `ANTHROPIC_BASE_URL=http://127.0.0.1:<port>` with
`_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1` keeps full OAuth subscription mode, and the
proxy swaps `Authorization` for the token of whichever account the session is assigned to
*right now*.

The proxy is not redundant with the namespace. A live Claude Code process resolves its
access token once at startup and never re-reads the Keychain — measured by swapping a
session's Keychain item mid-flight, which the session ignored while a new process failed
immediately. Rewriting the Keychain therefore cannot move a running session; only the
proxy can. It also means every response's `anthropic-ratelimit-unified-*` headers pass
through ccmux, so live usage costs no API calls.

## Install

    make install         # /Applications/ccmux.app + ~/.local/bin/ccmux
    make install-agent   # start at login (optional)
    ccmux shell-init     # prints the aliases; append them to ~/.zshrc

Then open the app once and **allow notifications**. This matters: an unanswered or
killed permission prompt leaves the bundle ID denied, and re-asking will not bring the
prompt back — you would have to switch it on by hand in System Settings › Notifications.
ccmux shows a banner with a button that takes you there if that happens.

Never launch the binary directly (`.build/…/ccmux` or the one inside the bundle) as a
GUI. Notification authorization depends on Launch Services, so always `open` the
installed app. CLI subcommands are fine to run directly.

## Add your subscriptions

In the app: **Accounts › Add account**. Pick the Chrome profile that is signed into the
Google account owning that subscription, and sign-in opens there — which is the point,
since several subscriptions on one Mac usually means several Chrome profiles. Chrome is
launched with `--profile-directory=` directly rather than through `open -a`, because
`open -a` silently drops that argument and would land the login in whichever profile was
frontmost.

`ccmux import` adopts the login Claude Code is already using, so your current account
becomes account #1 without signing in again.

## Use it

    cc-opus            # any account with 5-hour and weekly headroom
    cc-fable           # additionally needs Fable's own weekly window
    cc-any

Arguments pass straight through: `cc-opus --resume`, `cc-opus -p "…"`.

An alias names a *requirement*, not an account. `cc-fable` only considers accounts with
Fable weekly headroom left; `cc-opus` ignores that window entirely, so an account with
Fable spent is still a perfectly good Opus account. Edit the policies in Settings.

Among the accounts that qualify, ccmux picks the **most drained** one — least remaining
first, ranked on the **weekly** window that gates the request. The point is to finish one
subscription before starting the next, so the week does not end with several half-used
plans. Ranking ignores the 5-hour window on purpose: it refills all day, so ranking on it
would reshuffle the order every few hours without any of the subscription actually being
used up.

A session still needs somewhere decent to *start*, so each policy has a per-window launch
floor:

| policy | 5-hour | weekly (all) | weekly (model) |
|---|---|---|---|
| `cc-fable` | ≥ 5% | ≥ 3% | ≥ 3% |
| `cc-opus` | ≥ 3% | ≥ 1% | — |

Floors apply at launch only. A session already running takes whatever can still serve it,
because refusing a usable account mid-task parks the session when the alternative is a few
more useful requests. If nothing clears the floor, ccmux starts on the fullest account
anyway and says so on the shim line, rather than leaving you unable to work at all when
quota is tight.

Eligibility is never traded away for this. A Fable request will not take an account that
merely has general weekly headroom, however drained that account is — the model's own
weekly window has to have room.

**An alias picks the subscription, not the model.** It does not pass `--model`, and
`/model` inside the session keeps working exactly as it does normally — switch whenever
you like. The alias only decides which subscription the session starts on, and you can
change that yourself from the Sessions screen at any point.

If you do switch to a model whose own weekly window is spent on that account, the request
gets refused and auto-switch moves the session — and for that move it looks for an account
with headroom on *every* window rather than only the ones the launch policy cared about.

    ccmux status                       # accounts, windows, live sessions
    ccmux assign <session-id> <acct>   # same as the Sessions screen picker
    ccmux run --policy opus --account <id>   # pin one launch to one account

## The screens

The burger button top-left opens the curtain. A red dot on it — and on the Accounts
entry inside — means an account needs signing in again.

**Accounts** — per account: plan, health, and a bar per window (5-hour, weekly, and
weekly-per-model when the plan has one) with the reset countdown.

**Sessions** — every live session, joined with what Claude Code publishes in
`~/.claude/sessions/<pid>.json`: its own session name, busy/idle/waiting, cwd. Change a
session's account from the picker and it takes effect on that session's next request.
Sessions started as plain `claude` are listed too, marked as not managed.

Each session has a button that brings its iTerm tab to the front. Nothing is stored for
it: the handle is read from the process when you press it — the UUID out of its
`ITERM_SESSION_ID`, or its controlling tty — so it works on sessions that predate the
feature and on ones ccmux did not launch. macOS will ask once to let ccmux control
iTerm; because ccmux is ad-hoc signed it may ask again after an upgrade.

**Settings** — warning threshold, which windows it watches, auto-switch behaviour, the
Chrome profile each account's login page opens in, and the project-to-account bindings
below.

The Sessions screen also has a **Reassign** menu, which re-picks accounts for sessions
that are already running, as if they were launching now — either only the idle ones, or
all of them including mid-turn. Nothing does this on a timer: a session moves when it is
refused, or when you ask. It leaves alone any session whose auto-switch you turned off,
and any session on an account ccmux would never choose by itself (an API key, or one
held out of rotation), since those were put there deliberately.

## Projects that need a particular account

Connectors — the Slack, Drive and Jira integrations an administrator approves — belong
to an Anthropic **organization**, not to you. Claude Code fetches the list once at
startup, using the credential in its namespace. So the account a session *launches* on
fixes its connector set for the session's whole life: reassigning it later cannot add
them, and rotating it away cannot take them away.

That last part is what makes this workable. Bind a directory to an account in
Settings → **Project accounts**, and a session started anywhere under it launches in
that organization — then rotates for quota exactly as any other session does, keeping
the connectors it started with.

    ~/work/acme      → the account whose organization approved Slack

The deepest matching rule wins, so a subproject can override its parent, and matching is
per path component: a rule on `~/work/acme` never captures `~/work/acme-legacy`. A
binding names one account but means its whole organization, so a second seat in the same
organization is an equally good launch and ranking picks between them as usual. If every
account in that organization is spent, the session starts elsewhere rather than refusing
to start, and says so.

A binding reaches an account you have held **out of rotation** — "never pick this on
your own, except here" is the point of pairing the two. It will not reach an API key:
spending money stays a per-session decision.

`ccmux run --account <id>` overrides any binding, for a one-off.

## Running out

At the threshold (3% headroom by default) you get a notification. When a window is
actually hit, the session moves to the best remaining account that satisfies its policy.

**Failover happens before Claude Code sees the refusal.** A limit refusal comes back
through the proxy first, so ccmux re-issues the same request on an account that can
actually serve it and returns that response — the session never learns there was a
problem and never parks. Eligibility is computed per request against the windows that
really gate it: the 5-hour window, the weekly-all window, and the weekly window for the
*model named in the request body*. A spent Fable week does not stop an Opus call.

**When nothing can serve it**, ccmux rewrites `anthropic-ratelimit-unified-reset` on the
refusal to the soonest moment *any* account frees up before handing it to Claude Code.
That header is where Claude Code reads the time for its automatic continue, and it
refuses to wait at all when the reset is more than 24 hours out. Left alone, a session
that hit a Fable weekly limit would be told to wait three days, give up, print
"`/model` to switch models" and sit idle all night — even though another subscription
was four hours from freeing up. Now it is told the four hours, arms its own auto-continue
and resumes itself, and step one puts it on whichever account is live by then.

The residual case: if every account really is days away, Claude Code still declines to
wait and you get a notification instead. Nothing ccmux can do about that without
switching models for you, which it does not.

A switch costs the prompt cache: the next request re-reads the whole conversation at full
price. That is inherent to changing accounts mid-conversation, not something ccmux can
avoid — which is what **At turn boundary** is for. In that mode a session that is mid-answer
keeps going on the exhausted account and moves as soon as Claude Code goes idle, so the
cache is dropped between turns rather than inside one. **Immediately** switches on the very
next request.

## Keeping the 5-hour window rolling

The 5-hour window starts on first use, not on a clock — leave an account alone overnight
and its clock is simply stopped. Sit down at 09:00 and the window starts *then*, so the
next boundary is 14:00.

When an account's clock is stopped, ccmux sends one minimal Haiku request to start it, so
the cycle keeps turning while you are away and there is less of it left to wait out when
you come back. Measured on a real account: `five_hour.resets_at` went from null to a real
timestamp while utilization stayed at **0%**, for 22 input and 1 output token. Haiku is
used deliberately — the 5-hour window is account-wide so any model starts it, and Haiku
leaves the Fable and Opus weekly windows alone.

The signal is a missing `resets_at`, not zero usage: a window that has started but is
unused reports 0% *with* a reset time and is left alone, so this is one probe per account
per cycle. Toggle it off in Settings › Limit windows.

## Credentials, and why nothing races

Anthropic rotates refresh tokens, so two independent refreshers on one credential lineage
means whichever refreshes second is told `invalid_grant` and is logged out. A session's
Claude Code would otherwise be that second refresher, every eight hours.

ccmux removes the race rather than coordinating it. Each session namespace is seeded with
a live access token, an expiry a year out, and **no refresh token at all** — so Claude
Code never schedules a refresh and could not perform one anyway. (Verified against Claude
Code 2.1.238: it reports `loggedIn: true` for the right account with such a credential.)
Inference is unaffected because the proxy substitutes the real token on every request, and
ccmux re-seeds the namespace whenever it refreshes, so Claude Code's own profile and
`/usage` calls keep working too.

That makes ccmux the only holder of a refresh token, by construction. When its refresh
fails permanently, that account is marked as needing re-login — red dot on the burger
button and on the Accounts entry, a notification, and a **Sign in again** button that
opens in that account's Chrome profile.

One consequence worth knowing: if you also stay logged in globally with an account ccmux
manages, Claude Code's *global* login still holds its own refresh token for that same
lineage, and eventually one of the two will lose it. Either keep the global login on an
account ccmux does not manage, or sign in once more and let ccmux own it from then on.
Logging in globally as a *different* account is fine and does not disturb ccmux's copies.

Keychain access shells out to `/usr/bin/security` rather than using Security.framework: an
in-process call binds the item's ACL to the calling binary, which is re-signed on every
rebuild, so macOS would prompt after each build. `security` never changes, so creator ==
reader and there is no prompt.

## More than one Mac

Setting a second machine up means signing in to every account again, and neither Mac knows
what the other has spent. `ccmuxd` fixes that: a small Go server that holds every account and
is the sole holder of every refresh lineage. It hands out short-lived access tokens and
nothing that could rotate a lineage — inference still goes straight from each Mac to
Anthropic. Standard library only, ~7 MB static binary, idles at 25 MB of RAM.

    make ccmuxd-linux
    scp dist/ccmuxd-linux-amd64 scripts/install-ccmuxd.sh you@host:
    ssh you@host 'sudo ./install-ccmuxd.sh --mode systemd \
        --binary ./ccmuxd-linux-amd64 --dns ccmux.example.com --ip 203.0.113.10'

Then Settings → Account server on each Mac. ccmux shows you the certificate to confirm
before it sends anything, and pins it from then on. Accounts the server already has are
handed over; accounts only this Mac has are offered one checkbox at a time, because pushing
one uploads its refresh token.

Signing in again still happens in the browser here — the server is headless — but the PKCE
verifier and the code exchange are the server's, so the refresh token is born there. The
redirect stays on this Mac's loopback, which is why none of it needs Anthropic to accept a
public redirect URI.

See [docs/server.md](docs/server.md), including what it costs: the server becomes a
dependency, and token refreshes start coming from its IP rather than your laptop's.

## Where things live

    ~/Library/Application Support/ccmux/    accounts.json, usage.json, sessions.json,
                                            settings.json, ccmux.log, control.sock, ns/
    Keychain "ccmux-credentials"             one item per account, keyed by account uuid
    Keychain "ccmux-server"                  the ccmuxd basic-auth password

The control socket is a unix socket in a 0700 directory and checks the peer's uid: it
hands out session tokens, so it is not a TCP port.

## Develop

    swift build
    make test          # plain `swift test` fails on a CLT-only machine
    make test-server   # ccmuxd (Go), race detector on
    make ccmuxd-linux  # the static Linux binary that ships
    make app           # dist/ccmux.app
    make restart   # restart without losing live sessions
    make upgrade   # install, then that restart
    make icon      # re-renders Resources/AppIcon.icns from Sources/CCMuxKit/UI/IconArt.swift

Restarting deserves the dedicated target. Every live session's proxy port is written into
its `ANTHROPIC_BASE_URL` and cannot move, so a restart has to give each one its port
back. `make restart` waits for the app to exit rather than sleeping, relaunches, and then
verifies every session's port is listening again — and the app drains in-flight requests
on SIGTERM instead of severing them. A port that is momentarily taken no longer ends the
session: it is parked, retried every few seconds, and shown as such on its card.
