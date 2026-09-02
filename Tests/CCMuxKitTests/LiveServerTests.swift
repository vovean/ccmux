import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

/// Drives the real `ServerClient` against a real, running ccmuxd.
///
/// The fixture suite pins the JSON shapes, but only this exercises the parts that live
/// between the two: TLS pinning against an actual certificate, the basic-auth header, URL
/// construction, HTTP/2 negotiation, and the client's own error mapping. ccmuxd is a
/// separate Go program, so none of that is covered by either language's compiler.
///
/// Opt-in, because it needs a server. `scripts/verify-server.sh` starts one and sets these:
///
///     CCMUXD_URL=https://127.0.0.1:28500 CCMUXD_PASSWORD=… CCMUXD_FINGERPRINT=… make test
@Suite("Live ccmuxd", .enabled(if: ProcessInfo.processInfo.environment["CCMUXD_URL"] != nil))
struct LiveServerTests {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private static func baseURL() throws -> URL {
        let raw = try #require(env["CCMUXD_URL"])
        return try #require(URL(string: raw))
    }

    private static func client() throws -> ServerClient {
        let password = try #require(env["CCMUXD_PASSWORD"])
        let fingerprint = try #require(env["CCMUXD_FINGERPRINT"])
        return ServerClient(baseURL: try baseURL(),
                            username: env["CCMUXD_USERNAME"] ?? "ccmux",
                            password: password, fingerprint: fingerprint)
    }

    /// The whole publish loop against a real ccmuxd: a set is published, this Mac edits
    /// one file, and the Upload button's bundle goes back.
    ///
    /// Worth a real server because the failure it guards against is silent and
    /// fleet-wide: publishing the whole local tree instead of one file would push every
    /// other unanswered edit to every Mac, and both ends would still agree on the hash.
    @Test func publishingOneEditedFileLeavesTheRestOfTheServersSetAlone() async throws {
        let client = try Self.client()
        // PUT /hooks replaces the whole bundle, so this test overwrites whatever the
        // server holds. Pointed at a real ccmuxd it would delete the fleet's hooks from
        // every Mac within the minute, so the original goes back on every exit.
        let original = try await client.hooks().files
        do {
            try await Self.driveThePublishLoop(client)
        } catch {
            _ = try? await client.pushHooks(original)
            throw error
        }
        _ = try await client.pushHooks(original)
    }

    private static func driveThePublishLoop(_ client: ServerClient) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccmux-live-hooks-\(UUID().uuidString)",
                                    isDirectory: true)
            .appendingPathComponent("managed", isDirectory: true)
        let baselineFile = root.deletingLastPathComponent()
            .appendingPathComponent("baseline.json")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let published = [HookFile(path: "a.sh", content: "#!/bin/sh\necho a\n",
                                  executable: true),
                         HookFile(path: "b.sh", content: "#!/bin/sh\necho b\n",
                                  executable: true)]
        _ = try await client.pushHooks(published)

        // This Mac writes the set, then edits both files — one the user will answer for,
        // one they will not.
        let bundle = try await client.hooks()
        _ = try HookSync.install(bundle.files, server: bundle.files, root: root,
                                 baselineFile: baselineFile)
        for (path, body) in [("a.sh", "#!/bin/sh\necho mine-a\n"),
                             ("b.sh", "#!/bin/sh\necho mine-b\n")] {
            try body.write(to: root.appendingPathComponent(path), atomically: true,
                           encoding: .utf8)
        }
        let hooks = HookSync.classify(local: ManagedHooks.onDisk(in: root),
                                      server: bundle.files,
                                      baseline: HookBaseline.load(from: baselineFile))
        #expect(hooks.allSatisfy { $0.state == .editedHere })

        let toPublish = try #require(HookSync.bundlePublishing("a.sh", in: hooks))
        _ = try await client.pushHooks(toPublish)

        let after = try await client.hooks()
        #expect(after.files.first { $0.path == "a.sh" }?.content == "#!/bin/sh\necho mine-a\n")
        // The unanswered edit stayed on this Mac.
        #expect(after.files.first { $0.path == "b.sh" }?.content == "#!/bin/sh\necho b\n")
        // And the two ends agree on the hash, which is what the sync compares.
        #expect(ManagedHooks.version(of: after.files) == after.version)

        let settled = HookSync.classify(local: ManagedHooks.onDisk(in: root),
                                        server: after.files,
                                        baseline: HookBaseline.load(from: baselineFile))
        #expect(settled.first { $0.path == "a.sh" }?.state == .inSync)
        #expect(settled.first { $0.path == "b.sh" }?.state == .editedHere)
    }

    @Test func theProbeAgreesWithTheFingerprintWePin() async throws {
        let probed = try await ServerClient.probeFingerprint(baseURL: try Self.baseURL())
        // What install-ccmuxd.sh prints, lower-cased and unseparated.
        #expect(probed == (Self.env["CCMUXD_FINGERPRINT"] ?? "").lowercased())
    }

    /// Nothing listens here, and a refused connection is the cheap shape of "this address
    /// does not work on this network" — the expensive shape is a tunnel that is down,
    /// which times out instead.
    private static func deadAddress() throws -> URL {
        try #require(URL(string: "https://127.0.0.1:9"))
    }

    @Test func anUnreachableAddressIsSkippedAndTheWorkingOneRemembered() async throws {
        let live = try Self.baseURL()
        let client = ServerClient(baseURLs: [try Self.deadAddress(), live],
                                  username: Self.env["CCMUXD_USERNAME"] ?? "ccmux",
                                  password: try #require(Self.env["CCMUXD_PASSWORD"]),
                                  fingerprint: try #require(Self.env["CCMUXD_FINGERPRINT"]))
        let health = try await client.health()
        #expect(health.apiVersion == ServerAPI.version)
        // Remembered, so the next request does not pay for the dead address again.
        #expect(client.activeBaseURL == live)
    }

    /// An answer is not a failure. Walking on to the next address after a 401 would turn a
    /// clear refusal into a confusing one, and would spend a wrong password against every
    /// address the user listed.
    @Test func anHTTPRefusalDoesNotFallThroughToTheNextAddress() async throws {
        let client = ServerClient(baseURLs: [try Self.baseURL(), try Self.deadAddress()],
                                  username: Self.env["CCMUXD_USERNAME"] ?? "ccmux",
                                  password: "nope",
                                  fingerprint: try #require(Self.env["CCMUXD_FINGERPRINT"]))
        await #expect(throws: ServerClientError.unauthorized) {
            _ = try await client.health()
        }
    }

    @Test func theProbeReportsWhichAddressAnswered() async throws {
        let live = try Self.baseURL()
        let found = try await ServerClient.probe(baseURLs: [try Self.deadAddress(), live])
        #expect(found.url == live)
        #expect(found.fingerprint == (Self.env["CCMUXD_FINGERPRINT"] ?? "").lowercased())
    }

    @Test func healthNegotiatesAndDecodes() async throws {
        let health = try await Self.client().health()
        #expect(health.apiVersion == ServerAPI.version)
        #expect(health.uptimeSeconds >= 0)
    }

    @Test func accountsDecode() async throws {
        // Whatever the server holds, the envelope must decode and the version must match.
        _ = try await Self.client().accounts()
    }

    /// A certificate outside the pin must fail loudly rather than silently re-trusting.
    @Test func aWrongPinIsRefused() async throws {
        let wrong = ServerClient(baseURL: try Self.baseURL(), username: "ccmux",
                                 password: Self.env["CCMUXD_PASSWORD"] ?? "",
                                 fingerprint: String(repeating: "00", count: 32))
        await #expect(throws: (any Error).self) { try await wrong.health() }
    }

    @Test func aWrongPasswordIsReportedAsUnauthorized() async throws {
        let fingerprint = try #require(Self.env["CCMUXD_FINGERPRINT"])
        let wrong = ServerClient(baseURL: try Self.baseURL(), username: "ccmux",
                                 password: "not-it", fingerprint: fingerprint)
        await #expect(throws: ServerClientError.unauthorized) { try await wrong.health() }
    }

    /// The login relay, minus the browser. Proves the PKCE URL the Go server builds is the
    /// one the client's own loopback flow expects.
    @Test func theLoginRelayIssuesALoopbackRedirect() async throws {
        let started = try await Self.client().startLogin(
            LoginStartRequest(redirectPort: 51234))
        #expect(!started.loginID.isEmpty)
        #expect(!started.state.isEmpty)
        let url = try #require(URLComponents(string: started.authorizeURL))
        let items = Dictionary(uniqueKeysWithValues:
            (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["redirect_uri"] == "http://localhost:51234/callback")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == started.state)
        #expect(items["client_id"] == OAuthClient.clientID)
    }

    /// A 404 from the token endpoint must reach the vault as a dead lineage, not as a
    /// network hiccup — that classification is what makes the account visibly broken and
    /// the sign-in-again button appear.
    @Test func anUnknownAccountIsReportedAsNoUsableCredential() async throws {
        await #expect(throws: RemoteTokenError.self) {
            _ = try await Self.client().grant(for: "definitely-not-an-account")
        }
    }

    /// And a genuine HTTP error still arrives as a readable message rather than raw JSON.
    /// The full exchange: one request reports this machine's list and returns everyone's.
    @Test func reportingSessionsRoundTrips() async throws {
        let client = try Self.client()
        let machineID = "test-\(UUID().uuidString)"
        let session = MachineSession(id: "s1", accountID: "acct-1",
                                     accountLabel: "Work", name: "api",
                                     directory: "/tmp/api", policy: "opus",
                                     status: "busy", startedSecondsAgo: 42)
        let response = try await client.reportSessions(
            machineID: machineID, MachineReport(label: "test-machine", sessions: [session]))

        #expect(response.apiVersion == ServerAPI.version)
        let mine = try #require(response.machines.first { $0.machineID == machineID })
        #expect(mine.label == "test-machine")
        #expect(mine.sessions.map(\.id) == ["s1"])
        #expect(mine.ageSeconds >= 0)

        // A GET sees the same thing without reporting anything.
        let fetched = try await client.sessions()
        #expect(fetched.machines.contains { $0.machineID == machineID })

        // A report is a whole snapshot: what is absent from the next one is gone.
        let emptied = try await client.reportSessions(
            machineID: machineID, MachineReport(label: "test-machine", sessions: []))
        let after = try #require(emptied.machines.first { $0.machineID == machineID })
        #expect(after.sessions.isEmpty)

        try await client.forgetMachine(machineID)
        let gone = try await client.sessions()
        #expect(!gone.machines.contains { $0.machineID == machineID })
    }

    /// Forgetting something the server does not have is not an error — on an older ccmuxd
    /// the route does not exist at all, and either way nothing is left behind.
    @Test func forgettingAnUnknownMachineIsQuiet() async throws {
        try await Self.client().forgetMachine("never-existed-\(UUID().uuidString)")
    }

    @Test func serverErrorsAreReadable() async throws {
        do {
            _ = try await Self.client().usage(for: "definitely-not-an-account")
            Issue.record("expected the request to fail")
        } catch let error as ServerClientError {
            let text = error.localizedDescription
            #expect(text.contains("no usage recorded"))
            #expect(!text.contains("{"))
        }
    }
}
