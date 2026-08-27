import AsyncHTTPClient
import CCMuxCore
import Foundation
import NIOCore
import NIOFoundationCompat

/// The server's outbound transport. Deliberately not URLSession: on Linux that means
/// FoundationNetworking and libcurl, and this process already has NIO loaded to serve
/// HTTPS. One HTTP stack instead of two, and no libcurl to static-link.
public struct AsyncHTTPClientTransport: HTTPTransport {
    private let client: HTTPClient
    /// A refusal body from the token endpoint is a few hundred bytes; a usage response a
    /// few KB. The cap is generous and exists so a wedged upstream cannot exhaust memory.
    private static let maxBodyBytes = 8 * 1024 * 1024

    public init(client: HTTPClient) {
        self.client = client
    }

    public func send(_ spec: HTTPRequestSpec) async throws -> HTTPReply {
        var request = HTTPClientRequest(url: spec.url.absoluteString)
        request.method = .init(rawValue: spec.method)
        for (name, value) in spec.headers { request.headers.add(name: name, value: value) }
        if let body = spec.body { request.body = .bytes(ByteBuffer(data: body)) }

        do {
            let response = try await client.execute(
                request, timeout: .milliseconds(Int64(spec.timeout * 1000)))
            let buffer = try await response.body.collect(upTo: Self.maxBodyBytes)
            var headers: [String: String] = [:]
            for header in response.headers { headers[header.name.lowercased()] = header.value }
            return HTTPReply(status: Int(response.status.code),
                             body: Data(buffer.readableBytesView),
                             headers: headers)
        } catch {
            throw HTTPTransportError.network("\(error)")
        }
    }
}
