# ccmux

Runs each Claude Code session on the subscription you choose, and moves a session to
another account when the one it is on runs out.

macOS 14+. SwiftPM + SwiftUI, built without Xcode.

## Why it works the way it does

Two mechanisms, both verified against the Claude Code binary rather than guessed:

**Per-session credential namespace.** `CLAUDE_SECURESTORAGE_CONFIG_DIR=<dir>` makes
Claude Code read its OAuth credential from Keychain service
`"Claude Code-credentials-" + sha256(NFC(dir))[0..8]` instead of the global
`"Claude Code-credentials"`. ccmux seeds that item, so Claude Code genuinely *is* the
assigned account — right email, right `/usage`, right limit banners. Config, history and
`~/.claude/projects` stay shared, unlike `CLAUDE_CONFIG_DIR`.

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
since three subscriptions on one Mac usually means three Chrome profiles. Chrome is
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

An alias names a *requirement*, not an account. `cc-fable` picks whichever account has
the most Fable weekly headroom; `cc-opus` ignores that window entirely, so an account
with Fable spent is still a perfectly good Opus account. Edit the policies in Settings.

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

**Settings** — warning threshold, which windows it watches, auto-switch behaviour, and
the Chrome profile each account's login page opens in.

## Running out

At the threshold (3% headroom by default) you get a notification. When a window is
actually hit, the session moves to the best remaining account that satisfies its policy.

A switch costs the prompt cache: the next request re-reads the whole conversation at full
price. That is inherent to changing accounts mid-conversation, not something ccmux can
avoid — which is what **At turn boundary** is for. In that mode a session that is mid-answer
keeps going on the exhausted account and moves as soon as Claude Code goes idle, so the
cache is dropped between turns rather than inside one. **Immediately** switches on the very
next request.

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

Keychain access shells out to `/usr/bin/security` rather than using Security.framework: an
in-process call binds the item's ACL to the calling binary, which is re-signed on every
rebuild, so macOS would prompt after each build. `security` never changes, so creator ==
reader and there is no prompt.

## Where things live

    ~/Library/Application Support/ccmux/    accounts.json, usage.json, sessions.json,
                                            settings.json, ccmux.log, control.sock, ns/
    Keychain "ccmux-credentials"             one item per account, keyed by account uuid

The control socket is a unix socket in a 0700 directory and checks the peer's uid: it
hands out session tokens, so it is not a TCP port.

## Develop

    swift build
    make test      # 81 tests; plain `swift test` fails on a CLT-only machine
    make app       # dist/ccmux.app
    make icon      # re-renders Resources/AppIcon.icns from Sources/CCMuxKit/UI/IconArt.swift
