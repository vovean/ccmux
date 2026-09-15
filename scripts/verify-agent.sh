#!/usr/bin/env bash
# Builds both modules, runs both suites under the race detector, regenerates the
# cross-language rule vectors and checks the Swift side still agrees with them.
#
# What `go build` cannot catch: the two implementations of the ranking rules drifting
# apart, and the wire fixtures changing shape underneath the Mac client.
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n=== %s\n' "$*"; }

say "server: build, vet, test"
(cd server && go build ./... && go vet ./... && go test -race ./...)

say "agent: build, vet, test"
(cd agent && go build ./... && go vet ./... && go test -race -count=1 ./...)

say "rule vectors are what the agent actually computes"
# Hashed, not counted: agent/ is untracked, so `git status` says the same thing whatever
# the files contain.
checksum() { find "$1" -type f -name '*.json' -exec shasum -a 256 {} + | sort -k2 | shasum -a 256; }
before=$(checksum agent/testdata/rules)
(cd agent && UPDATE_FIXTURES=1 go test ./internal/rules/ ./internal/ledger/ >/dev/null)
if [ "$before" != "$(checksum agent/testdata/rules)" ]; then
  echo "agent/testdata/rules changed when regenerated — commit the new vectors" >&2
  exit 1
fi

say "wire fixtures are what ccmuxd actually emits"
(cd server && UPDATE_FIXTURES=1 go test ./... >/dev/null)
if ! git -C . diff --quiet -- server/testdata/wire; then
  echo "server/testdata/wire changed when regenerated — commit the new fixtures" >&2
  exit 1
fi

say "swift: the other half of both contracts"
make test

say "the shipping binary"
make ccmux-linux

printf '\nall green\n'
