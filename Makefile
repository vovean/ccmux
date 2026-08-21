FW = /Library/Developer/CommandLineTools/Library/Developer/Frameworks
SWIFT_TEST_FLAGS = --disable-xctest --enable-swift-testing \
	-Xswiftc -F -Xswiftc $(FW) \
	-Xlinker -F -Xlinker $(FW) -Xlinker -rpath -Xlinker $(FW)

.PHONY: build app icon test install run clean install-agent uninstall-agent

build:
	swift build

icon:
	./scripts/make-icon.sh

app:
	./scripts/bundle.sh release

test:
	swift test $(SWIFT_TEST_FLAGS)

install: app
	rm -rf /Applications/ccmux.app
	cp -R dist/ccmux.app /Applications/ccmux.app
	mkdir -p $(HOME)/.local/bin
	ln -sf /Applications/ccmux.app/Contents/MacOS/ccmux $(HOME)/.local/bin/ccmux
	@echo "installed /Applications/ccmux.app and ~/.local/bin/ccmux"

run: install
	open /Applications/ccmux.app

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
