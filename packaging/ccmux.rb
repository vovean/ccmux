cask "ccmux" do
  version "1.0"
  sha256 "REPLACED_AT_RELEASE"

  url "https://github.com/vovean/ccmux/releases/download/v#{version}/ccmux-#{version}-arm64.zip",
      verified: "github.com/vovean/ccmux/"
  name "ccmux"
  desc "Runs each Claude Code session on a different Claude subscription"
  homepage "https://github.com/vovean/ccmux"

  # Apple Silicon only: the bundle ships a thin arm64 binary.
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "ccmux.app"
  # The CLI and the app are the same executable; the shell wrappers call it by this name.
  binary "#{appdir}/ccmux.app/Contents/MacOS/ccmux"

  # The app is ad-hoc signed rather than Developer ID signed and notarized, so Gatekeeper
  # blocks it once Homebrew's download carries the quarantine flag. Clearing it here is
  # what `--no-quarantine` would do, applied only to this app so the user does not have to
  # remember a flag. Notarizing instead would need an Apple Developer membership.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ccmux.app"],
                   sudo: false
  end

  uninstall launchctl: "io.vovean.ccmux",
            quit:      "io.vovean.ccmux",
            delete:    "#{appdir}/ccmux.app"

  # Accounts, sessions and usage live here; credentials are in the Keychain and are
  # deliberately not removed by zap, since they are shared with a reinstall.
  zap trash: [
    "~/Library/Application Support/ccmux",
    "~/Library/LaunchAgents/io.vovean.ccmux.plist",
  ]

  caveats <<~EOS
    Shell wrappers are not installed automatically. To add them:

      ccmux shell-init >> ~/.zshrc

    To start ccmux at login:

      ccmux install-agent

    Open the app once and allow notifications: a prompt that is dismissed leaves the
    bundle denied, and re-asking will not bring it back.
  EOS
end
