import Foundation
import Testing
@testable import CCMuxKit

@Suite("Chrome profiles")
struct ChromeProfileTests {
    /// Shape taken from a real Chrome `Local State`, trimmed to the read fields.
    static let localState = """
    {"profile": {
      "profiles_order": ["Profile 3", "Default"],
      "info_cache": {
        "Default": {"name": "Personal", "user_name": "me@gmail.com"},
        "Profile 3": {"name": "Work", "user_name": "me@company.com"},
        "Profile 9": {}
      }}}
    """

    @Test func parsesProfilesInChromesOwnOrder() throws {
        let profiles = ChromeProfileReader.parse(localState: Data(Self.localState.utf8))
        #expect(profiles.count == 3)
        // profiles_order first, then anything Chrome did not rank.
        #expect(profiles[0].directory == "Profile 3")
        #expect(profiles[1].directory == "Default")
        #expect(profiles[2].directory == "Profile 9")
        #expect(profiles[0].label == "Work — me@company.com")
    }

    /// Chrome owns this schema; a missing field must still leave a row the user can map
    /// by hand rather than losing the profile entirely.
    @Test func degradesRatherThanDroppingIncompleteRows() throws {
        let profiles = ChromeProfileReader.parse(localState: Data(Self.localState.utf8))
        let bare = try #require(profiles.first { $0.directory == "Profile 9" })
        #expect(bare.name == "Profile 9")
        #expect(bare.email == nil)
        #expect(bare.label == "Profile 9")
    }

    @Test func unparseableStateYieldsNoProfiles() {
        #expect(ChromeProfileReader.parse(localState: Data("nonsense".utf8)).isEmpty)
        #expect(ChromeProfileReader.parse(localState: Data("{}".utf8)).isEmpty)
    }
}

@Suite("Formatting")
struct FormatTests {
    @Test func countdownUsesTheCoarsestUsefulUnit() {
        let now = Date(timeIntervalSince1970: 1_787_355_000)
        #expect(Format.countdown(to: now.addingTimeInterval(90), from: now) == "1m")
        #expect(Format.countdown(to: now.addingTimeInterval(3 * 3600 + 720), from: now)
                == "3h 12m")
        #expect(Format.countdown(to: now.addingTimeInterval(2 * 86400 + 5 * 3600), from: now)
                == "2d 5h")
    }

    @Test func countdownNeverGoesNegative() {
        let now = Date(timeIntervalSince1970: 1_787_355_000)
        #expect(Format.countdown(to: now.addingTimeInterval(-9999), from: now) == "0m")
    }

    @Test func homeDirectoryIsAbbreviated() {
        #expect(Format.shortenHome("\(NSHomeDirectory())/Documents/x") == "~/Documents/x")
        #expect(Format.shortenHome("/etc/hosts") == "/etc/hosts")
    }
}

@Suite("Settings defaults")
struct SettingsTests {
    @Test func defaultPoliciesCoverBothAliases() throws {
        let settings = Settings()
        #expect(settings.warnThresholdPercent == 3)
        let opus = try #require(settings.policy(named: "opus"))
        #expect(!opus.requiredWindows.contains(.weeklyScoped))
        let fable = try #require(settings.policy(named: "fable"))
        #expect(fable.requiredWindows.contains(.weeklyScoped))
        #expect(fable.scopedModel == "Fable")
    }

    @Test func policyLookupIsCaseInsensitive() {
        #expect(Settings().policy(named: "OPUS") != nil)
        #expect(Settings().policy(named: "nope") == nil)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        var settings = Settings()
        settings.warnThresholdPercent = 7
        settings.autoSwitch = .atTurnBoundary
        settings.mutedAccountIDs = ["a"]
        let data = try JSONStore.encoder.encode(settings)
        #expect(try JSONStore.decoder.decode(Settings.self, from: data) == settings)
    }
}
