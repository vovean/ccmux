# ccmuxd — the account server

One place that holds every Claude account and its refresh lineage, so a second Mac imports
them instead of signing in to all of them again.

It is **not** a proxy for inference. Sessions still run their own local proxies and talk to
Anthropic directly from the Mac. The server does two things: hand out short-lived access
tokens, and keep the lineages alive.

## Why a server at all

ccmux has always had one hard constraint:

> Multiple refresh lineages per account are fine. Two holders of **one** lineage are not —
> Anthropic rotates refresh tokens, so whichever refreshes second is told `invalid_grant`
> and is logged out for good.

Two Macs each holding their own lineage for the same account is safe, but it means signing
in twice, and neither knows what the other has spent. A server that is the *sole* holder of
every lineage fixes both, and it is the shape the constraint was always pointing at.

## What crosses the wire

| Direction | Carries | When |
|---|---|---|
| server → client | access token, expiry, plan | every renewal |
| server → client | account metadata, usage snapshots | on connect and each tick |
| client → server | **refresh token** | `adopt` only, and only when you tick that account |

A refresh token never appears in a response. That is enforced by what `TokenGrant` can
carry, not by remembering to strip a field, and there is a test asserting the encoded form
of a grant never contains one.

## Sign-in, and why there is no SSH tunnel

The server is headless, so it cannot open a browser. But the code never needs to reach it:

1. Client asks the server to start a login.
2. Server generates the PKCE pair, **keeps the verifier**, returns the authorize URL with
   `redirect_uri=http://localhost:<client port>/callback`.
3. Client opens Chrome in the right profile and listens on that port — the same flow it has
   always used.
4. Browser lands back on the client. The client relays the code to the server.
5. Server exchanges it. The refresh token is born there and never leaves.

So the redirect stays on loopback, and none of this depends on Anthropic accepting a
raw-IP or public redirect URI.

What was measured on 2026-08-27, for the record: `claude.com/cai/oauth/authorize` rewrites
`127.0.0.1` to `localhost` and passes any other host through untouched, and
`claude.ai/oauth/authorize` renders the org picker with a raw LAN IP as `redirect_uri`
rather than rejecting it. Whether that survives the final redirect and the code exchange
was **not** established — the token endpoint rate-limits unauthenticated probes, and it is
the same endpoint keeping live sessions alive. The design does not depend on the answer.

## What it is

A single Go program, standard library only — no external modules at all. It
cross-compiles to a ~7 MB static Linux binary from any machine with Go, needs no runtime
on the target, and idles at about 25 MB of RAM.

That last part is why it is not Swift. A Linux Swift build needs a 1.2 GB toolchain
downloaded first, and on a 961 MB VPS the Docker route would have spent ~1.5 GB of disk
and ~200 MB of RAM to run a workload this size — where an OOM reaches whatever else the
box is running, not just ccmuxd.

## Install

Build the binary, copy it and the script over, and run it:

```sh
make ccmuxd-linux                        # dist/ccmuxd-linux-amd64, ~7 MB
scp dist/ccmuxd-linux-amd64 scripts/install-ccmuxd.sh you@host:
ssh you@host 'sudo ./install-ccmuxd.sh --mode systemd \
    --binary ./ccmuxd-linux-amd64 --dns ccmux.example.com --ip 203.0.113.10'
```

Pass every name and address you will actually use. They become the certificate's SANs, and
a client reaching the server by a name the certificate does not cover will refuse the
connection.

That installs to `/usr/local/bin/ccmuxd`, creates a `ccmuxd` system user, puts the sealed
store in `/var/lib/ccmuxd` and the certificate in `/etc/ccmuxd`, and starts a systemd unit
with the usual hardening plus a `MemoryMax` — so ccmuxd can never be the reason something
else on the box gets killed.

The script prints the password **once** and the certificate fingerprint. Delete
`/var/lib/ccmuxd/auth` and rerun it to issue a new password.

A `server/Dockerfile` exists for hosts where a container is the house style; it builds a
`scratch` image of the binary plus a CA bundle, under 10 MB.

## Connecting a Mac

Settings → Account server. Enter the address, username and password, and ccmux completes a
handshake and shows you the certificate to confirm — it sends no credentials until you
agree to it. Compare it with what the install script printed.

The pin is checked on **every** request afterwards, not just the first. A self-signed
certificate has no authority behind it, so the pin is the only thing distinguishing the
server from anything else answering on that address.

## Delegation

On connect, ccmux sorts the accounts three ways:

- **On both sides** → delegated. This Mac stops refreshing the account and asks the server
  for tokens instead.
- **Only on the server** → imported.
- **Only on this Mac** → offered, one checkbox each. Pushing uploads that account's refresh
  token, so it is never automatic.
- **On the server but flagged as needing re-login** → left alone, and named. Handing over
  to a dead lineage would trade a working local credential for a broken remote one.

Subscriptions match on `Account.id`, which is the Anthropic account UUID and is identical
on every machine. API-key accounts cannot: their id is a UUID generated by whichever Mac
added the key, so they match on a SHA-256 of the key itself, and the local record is
renumbered onto the server's id.

Handing over is **mint-then-delete**: the server has to produce a *usable* token — present
and not already expired — before the local refresh token is overwritten. A server that
holds the account but whose own lineage is dead would otherwise leave you with nothing on
either side. Orphaning the local lineage is safe precisely because lineages are
independent — it simply expires, unrefreshed.

Pushing inverts the order, and has to. Once `adopt` succeeds the server is already a holder
of that lineage, so the Mac commits to delegation and drops its refresh token immediately,
before fetching the first token. Waiting until the fetch succeeded would leave both sides
refreshing one lineage if it failed, which is the case that logs an account out for good.

Live sessions do not notice. The proxy swaps the auth header per request, so the next call
uses a server-issued token with no restart.

## Endpoints

All under `/v1`, all behind basic auth.

```
GET    /health                     apiVersion, account count, uptime
GET    /accounts                   metadata only, no secrets
GET    /accounts/{id}/token        access token + expiresIn, or the API key
GET    /accounts/{id}/usage        cached windows + age
POST   /login/start                → loginID, authorizeURL, state
POST   /login/finish               → the account
POST   /accounts/adopt             credentialJSON or apiKey
DELETE /accounts/{id}
```

`expiresIn` is **seconds, not a timestamp**. A laptop and a server do not agree on the wall
clock, and a client trusting a remote absolute time would treat dead tokens as live.

## Usage polling

The server polls, clients read. The usage endpoint budgets roughly 28 requests per hour per
token, and two Macs polling the same account independently spend it twice for the same
numbers. Polling cadence comes from `PollPolicy`, the same code the app uses; the server has
no session knowledge, so it treats an account as in use if a client asked for its token in
the last ten minutes.

## What this costs you

Worth knowing before you rely on it.

1. **The server is now a dependency.** If it is down, new sessions on delegated accounts
   cannot start, and running ones stop when their cached access token expires (about an
   hour). The client keeps the last token and its expiry, so a brief outage is invisible; a
   long one is not. An unreachable server is treated as a *transient* failure and never
   marks an account as needing re-login — and a delegated account will not fall back to a
   local refresh grant, because its credential has no refresh token and the attempt would
   fail permanently.
2. **Refresh and inference come from different IPs.** Anthropic sees token refreshes from
   the server and inference from laptops, on the same account. On company accounts under a
   CISO's eye, that is the limitation to weigh hardest.
3. **Two Macs still rank independently.** Both will pick the account with the most headroom
   and drain it together. The server could publish an advisory "sessions elsewhere" count;
   it does not yet.
4. **One shared credential.** Basic auth means revoking one Mac rotates the password for all
   of them.
5. **Back up `data/`.** It holds every refresh lineage, sealed with `master.key` sitting
   beside it. Losing it means signing every account in again. Both files are 0600 in a 0700
   directory; the sealing protects a stray copy of the sealed file, not much more.
6. **Connectors are unaffected.** They are organisation-scoped and resolved when Claude Code
   starts. Pulling the credential from a server changes nothing there.

## Disconnecting

Settings → Disconnect. Delegated accounts hold an access token and no refresh token, so
this Mac cannot renew them at all — ccmux says which ones will need signing in again here.
The server keeps its copies; nothing is deleted.

## Development

```sh
make build-server     # go build + go vet
make test-server      # go test -race
make ccmuxd-linux     # the artifact that ships
```

The end-to-end suite starts a real TLS server on a kernel-assigned port and drives the
real routes through it, pinning the certificate the same way the Mac does.

**The cross-language contract** is the part worth understanding. The client is Swift and
models this protocol independently, so nothing the compiler does can catch a renamed key
or a reformatted date — it would surface as a broken client on someone's Mac.
`server/fixtures_test.go` writes `server/testdata/wire/*.json` from the server's own
marshalling, and `Tests/CCMuxKitTests/ServerWireCompatibilityTests.swift` decodes those
exact bytes with the real client types. Change the shape on either side and one of them
fails.

The sharpest edge it guards: Swift's `.iso8601` decoding strategy rejects fractional
seconds, and Go's default time marshalling emits them. The server carries a custom time
type purely so usage timestamps stay decodable.
