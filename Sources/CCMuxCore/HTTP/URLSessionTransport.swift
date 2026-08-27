#if canImport(Darwin)
import Foundation

/// The Darwin transport. Deliberately not compiled on Linux — see `HTTPTransport`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ spec: HTTPRequestSpec) async throws -> HTTPReply {
        var request = URLRequest(url: spec.url)
        request.httpMethod = spec.method
        request.httpBody = spec.body
        request.timeoutInterval = spec.timeout
        for (name, value) in spec.headers { request.setValue(value, forHTTPHeaderField: name) }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HTTPTransportError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPTransportError.notHTTP }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        return HTTPReply(status: http.statusCode, body: data, headers: headers)
    }
}
#endif
