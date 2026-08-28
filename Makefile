FW = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
SWIFT_TEST_FLAGS = --disable-xctest --enable-swift-testing \
	-Xswiftc -F -Xswiftc $(FW) \
	-Xlinker -F -Xlinker $(FW) -Xlinker -rpath -Xlinker $(FW)

.PHONY: build app icon test install run restart upgrade clean install-agent \
	uninstall-agent release publish test-server build-server ccmuxd-linux ccmuxd-image \
	verify-server

build:
	swift build

icon:
	./scripts/make-icon.sh

app:
	./scripts/bundle.sh release

test:
	swift test $(SWIFT_TEST_FLAGS)

# ccmuxd is Go: standard library only, no external modules, and it cross-compiles to a
# static Linux binary from anywhere. That last part is why it is not Swift — a Linux Swift
# build needs a 1.2 GB toolchain downloaded first, which is exactly what blocked the
# original deployment.
build-server:
	cd server && go build ./... && go vet ./...

test-server:
	cd server && go test -race ./...

# The artifact that actually ships. ~7 MB, statically linked, no runtime on the target.
ccmuxd-linux:
	@mkdir -p dist
	cd server && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
	  go build -trimpath -ldflags="-s -w" -o ../dist/ccmuxd-linux-amd64 .
	@ls -lh dist/ccmuxd-linux-amd64 | awk '{print "  dist/ccmuxd-linux-amd64", $$5}'

ccmuxd-image:
	docker build -f server/Dockerfile -t ccmuxd:latest server

# Starts a real ccmuxd with a real certificate and drives it with the real Mac client.
# Covers what neither compiler can: TLS pinning, the auth header, HTTP/2, error mapping.
verify-server:
	./scripts/verify-server.sh

install: app
	rm -rf /Applications/ccmux.app
	cp -R dist/ccmux.app /Applications/ccmux.app
	mkdir -p $(HOME)/.local/bin
	ln -sf /Applications/ccmux.app/Contents/MacOS/ccmux $(HOME)/.local/bin/ccmux
	@echo "installed /Applications/ccmux.app and ~/.local/bin/ccmux"

run: install
	open /Applications/ccmux.app

# Restarts what is installed without losing live sessions: waits for a clean exit,
# then verifies every session's proxy port came back. See scripts/restart.sh.
restart:
	./scripts/restart.sh

upgrade: install restart

install-agent:
	mkdir -p $(HOME)/Library/LaunchAgents
	cp Resources/io.vovean.ccmux.plist $(HOME)/Library/LaunchAgents/
	launchctl bootout gui/$$(id -u)/io.vovean.ccmux 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(HOME)/Library/LaunchAgents/io.vovean.ccmux.plist
	@echo "ccmux will start at login"

uninstall-agent:
	launchctl bootout gui/$$(id -u)/io.vovean.ccmux 2>/dev/null || true
	rm -f $(HOME)/Library/LaunchAgents/io.vovean.ccmux.plist
	@echo "login item removed"

clean:
	rm -rf .build dist

# Release artifact for the Homebrew tap. ditto, not zip: it preserves the bundle's
# resource forks and the ad-hoc signature, which a plain zip can disturb.
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ARCH := $(shell uname -m)
RELEASE = dist/ccmux-$(VERSION)-$(ARCH).zip

release: app
	@rm -f $(RELEASE)
	@cd dist && ditto -c -k --sequesterRsrc --keepParent ccmux.app $(notdir $(RELEASE))
	@codesign -v dist/ccmux.app && echo "signature ok"
	@echo "artifact : $(RELEASE)"
	@echo "size     : $$(du -h $(RELEASE) | cut -f1)"
	@echo "sha256   : $$(shasum -a 256 $(RELEASE) | cut -d' ' -f1)"
	@echo "version  : $(VERSION)   arch: $(ARCH)"

# Cuts and publishes a release end to end: tests, clean build, version bump, tag, GitHub
# release, and the tap's cask. Guarded at every step — see scripts/publish.sh.
#   make publish VERSION=1.1
# VERSION defaults to Info.plist for `release`, which would make a bare `make publish`
# silently re-cut the current version. Publishing must be deliberate, so it is only
# accepted from the command line.
publish:
	@[ "$(origin VERSION)" = "command line" ] || { \
	  echo "publish: pass a version, e.g. make publish VERSION=1.1" >&2; exit 1; }
	@./scripts/publish.sh $(VERSION)
