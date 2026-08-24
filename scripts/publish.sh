#!/bin/zsh
# Cuts a release: bumps the version, tags, publishes the artifact, updates the tap.
#
#   make publish VERSION=1.1
#
# Every step is guarded, because the expensive mistake here is a tag or a release that
# does not match the artifact people download.
set -euo pipefail

VERSION="${1:-}"
TAP="${TAP:-$HOME/Documents/homebrew-tap}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

die() { print -u2 "publish: $1"; exit 1 }

[[ -n "$VERSION" ]] || die "VERSION is required, e.g. make publish VERSION=1.1"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || die "VERSION must look like 1.1 or 1.1.2"
[[ -d "$TAP/.git" ]] || die "no tap checkout at $TAP (override with TAP=…)"
command -v gh >/dev/null || die "gh is not installed"

[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit or stash first"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "master" ]] || die "not on master"
git rev-parse "v$VERSION" >/dev/null 2>&1 && die "tag v$VERSION already exists"

print "==> tests"
make test >/dev/null || die "tests failed"

print "==> clean build (warnings are treated as a stop)"
rm -rf .build
if swift build 2>&1 | grep -qiE 'warning|error'; then
  die "build is not clean"
fi

print "==> version -> $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Resources/Info.plist
git add Resources/Info.plist
git commit -q -m "Release $VERSION"

print "==> artifact"
make release VERSION="$VERSION" >/dev/null
ARTIFACT="dist/ccmux-$VERSION-$(uname -m).zip"
[[ -f "$ARTIFACT" ]] || die "expected $ARTIFACT"

# The binary must agree with the tag. A hardcoded constant once shipped a 1.1 bundle whose
# CLI still said 1.0, and nothing in the pipeline noticed.
BUILT="$(dist/ccmux.app/Contents/MacOS/ccmux --version 2>/dev/null | awk '{print $2}')"
[[ "$BUILT" == "$VERSION" ]] || die "built binary reports '$BUILT', expected '$VERSION'"
SHA="$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)"

print "==> tag and push"
git tag -a "v$VERSION" -m "ccmux $VERSION"
git push -q origin master
git push -q origin "v$VERSION"

print "==> github release"
NOTES="$(git log --pretty='- %s' "$(git describe --tags --abbrev=0 "v$VERSION^" 2>/dev/null || echo HEAD)..v$VERSION^" 2>/dev/null | grep -v '^- Release ' || true)"
[[ -n "$NOTES" ]] || NOTES="See the commit history for what changed."
# print -r --: the notes begin with "- ", and zsh's print reads a leading dash as an
# option. Without the terminator this dies after gh has already created the release.
print -r -- "$NOTES" | gh release create "v$VERSION" "$ARTIFACT" \
  --title "ccmux $VERSION" --notes-file - >/dev/null

# The published bytes are what people install, so the cask must be pinned to those and
# not to a local build that happens to be lying around.
print "==> verifying the published artifact"
URL="https://github.com/vovean/ccmux/releases/download/v$VERSION/ccmux-$VERSION-$(uname -m).zip"
TMP="$(mktemp)"
curl -sSL -o "$TMP" "$URL"
DL_SHA="$(shasum -a 256 "$TMP" | cut -d' ' -f1)"
rm -f "$TMP"
[[ "$DL_SHA" == "$SHA" ]] || die "published artifact hashes $DL_SHA, expected $SHA"

print "==> tap"
git -C "$TAP" pull -q --ff-only
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
    "$REPO_ROOT/packaging/ccmux.rb" > "$TAP/Casks/ccmux.rb"
sed -i '' "s/REPLACED_AT_RELEASE/$SHA/" "$TAP/Casks/ccmux.rb"
git -C "$TAP" add Casks/ccmux.rb
git -C "$TAP" commit -q -m "ccmux $VERSION"
git -C "$TAP" push -q

print ""
print "published ccmux $VERSION"
print "  sha256 : $SHA"
print "  release: https://github.com/vovean/ccmux/releases/tag/v$VERSION"
print "  install: brew update && brew upgrade --cask ccmux"
