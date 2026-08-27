import AsyncHTTPClient
import CCMuxCore
import CCMuxDaemonKit
import Foundation
import Hummingbird
import HummingbirdTLS
import Logging
import NIOSSL

@main
struct Daemon {
    /// One housekeeping tick per interval. Short enough that a lineage is refreshed well
    /// before a client needs the token, long enough that the usage endpoint's hourly
    /// budget stays governed by `PollPolicy` rather than by this loop.
    static let tickInterval: Duration = .seconds(20)

    static func main() async {
        do {
            try await start()
        } catch let error as ServerError {
            FileHandle.standardError
                .write(Data("ccmuxd: \(error.errorDescription ?? "failed")\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("ccmuxd: \(error)\n".utf8))
            exit(1)
        }
    }

    static func start() async throws {
        let config = try ServerConfig.parse(Array(CommandLine.arguments.dropFirst()),
                                            environment: ProcessInfo.processInfo.environment)
        // journald collects stdout; there is no os_log here and no app log file.
        Log.configure(fileURL: nil, echoToStandardOutput: true)

        try FileManager.default.createDirectory(at: config.dataDir,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let credential = try BasicAuthCredential.load(from: config.authFile)
        let key = try EncryptedFileSecretStore.loadOrCreateKey(at: config.masterKeyFile)
        let secrets = EncryptedFileSecretStore(fileURL: config.secretsFile, key: key)

        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        let oauth = OAuthClient(transport: AsyncHTTPClientTransport(client: httpClient))

        let registry = AccountRegistry(client: oauth, secrets: secrets,
                                       accountsFile: config.accountsFile)
        await registry.bootstrap()

        let router = Routes.build(registry: registry, credential: credential)
        var logger = Logger(label: "ccmuxd")
        logger.logLevel = .info

        let address = BindAddress.hostname(config.host, port: config.port)
        let tlsConfiguration = config.insecure ? nil : try tls(config)
        let application: any ApplicationProtocol
        if let tlsConfiguration {
            application = Application(router: router,
                                      server: try .tls(tlsConfiguration: tlsConfiguration),
                                      configuration: .init(address: address,
                                                           serverName: "ccmuxd"),
                                      logger: logger)
        } else {
            Log.warn("serving plain HTTP — the basic-auth credential and every access "
                     + "token it returns travel in the clear")
            application = Application(router: router,
                                      configuration: .init(address: address,
                                                           serverName: "ccmuxd"),
                                      logger: logger)
        }

        Log.info("ccmuxd listening on \(config.host):\(config.port) "
                 + (config.insecure ? "(plain HTTP)" : "(TLS)"))

        // The housekeeping loop is a plain task rather than a lifecycle Service: it has
        // no shutdown ordering requirements — a tick that is cut off mid-refresh simply
        // runs again next start, because the rotated credential is persisted before the
        // in-memory copy is considered current.
        let housekeeping = Task {
            while !Task.isCancelled {
                await registry.tick()
                try? await Task.sleep(for: tickInterval)
            }
        }
        defer { housekeeping.cancel() }

        do {
            try await application.runService()
        } catch {
            try? await httpClient.shutdown()
            throw error
        }
        try? await httpClient.shutdown()
    }

    private static func tls(_ config: ServerConfig) throws -> TLSConfiguration {
        let fm = FileManager.default
        guard fm.fileExists(atPath: config.certPath), fm.fileExists(atPath: config.keyPath) else {
            throw ServerError.startup(
                "no certificate at \(config.certPath) / \(config.keyPath) — "
                + "run scripts/install-ccmuxd.sh, or pass --insecure behind a TLS front end")
        }
        do {
            let chain = try NIOSSLCertificate.fromPEMFile(config.certPath).map {
                NIOSSLCertificateSource.certificate($0)
            }
            let key = try NIOSSLPrivateKey(file: config.keyPath, format: .pem)
            return TLSConfiguration.makeServerConfiguration(certificateChain: chain,
                                                            privateKey: .privateKey(key))
        } catch {
            throw ServerError.startup("could not load the certificate: \(error)")
        }
    }
}
