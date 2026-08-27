import Foundation

/// One outbound HTTP request, described without reference to URLSession.
///
/// The indirection exists for one reason: on Linux `URLSession` lives in
/// FoundationNetworking and pulls in libcurl, which is the usual source of static-linking
/// and TLS trouble. The server already needs NIO to *serve* HTTPS, so it uses
/// async-http-client to *make* its calls and never links libcurl at all.
public struct HTTPRequestSpec: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:],
                body: Data? = nil, timeout: TimeInterval = 30) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPReply: Sendable {
    public var status: Int
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ spec: HTTPRequestSpec) async throws -> HTTPReply
}

public enum HTTPTransportError: Error, LocalizedError {
    case network(String)
    case notHTTP

    public var errorDescription: String? {
        switch self {
        case .network(let s): return s
        case .notHTTP: return "not an HTTP response"
        }
    }
}
