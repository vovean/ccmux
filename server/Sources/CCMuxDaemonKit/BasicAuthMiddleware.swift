import CCMuxCore
import Foundation
import HTTPTypes
import Hummingbird

/// Basic auth on every route. The credential is a single shared one by design; see
/// docs/server.md for what that costs.
public struct BasicAuthMiddleware<Context: RequestContext>: RouterMiddleware {
    public let credential: BasicAuthCredential

    public func handle(_ request: Request, context: Context,
                next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let header = request.headers[.authorization],
              let supplied = BasicAuthHeader.parse(header),
              credential.accepts(username: supplied.username, password: supplied.password) else {
            // The realm is what makes a browser and `curl -u` offer a prompt rather than
            // just failing, which matters because this is also how you check the server
            // by hand.
            var response = Response(status: .unauthorized)
            response.headers[.wwwAuthenticate] = #"Basic realm="ccmuxd", charset="UTF-8""#
            return response
        }
        return try await next(request, context)
    }

}

/// Split out of the middleware so it can be tested without naming a request context.
public enum BasicAuthHeader {
    public static func parse(_ header: String) -> (username: String, password: String)? {
        let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0].caseInsensitiveCompare("Basic") == .orderedSame,
              let decoded = Data(base64Encoded: parts[1]),
              let text = String(data: decoded, encoding: .utf8) else { return nil }
        // Split on the first colon only: a password may legitimately contain one.
        guard let separator = text.firstIndex(of: ":") else { return nil }
        return (String(text[text.startIndex..<separator]),
                String(text[text.index(after: separator)...]))
    }
}
