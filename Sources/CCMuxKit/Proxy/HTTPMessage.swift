import Foundation

/// Incremental HTTP/1.1 request parser for the proxy's inbound leg.
///
/// Only what a Claude Code client actually sends has to work: an absolute-path
/// request line, LF-terminated headers, and a body framed by Content-Length or
/// chunked transfer coding.
struct HTTPRequestParser {
    struct Request {
        var method: String
        var target: String
        var headers: [(name: String, value: String)]
        var body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var wantsKeepAlive: Bool {
            (header("Connection") ?? "keep-alive").caseInsensitiveCompare("close") != .orderedSame
        }
    }

    enum ParseError: Error {
        case malformed(String)
        case tooLarge
    }

    /// Bodies above this are refused rather than buffered. Claude Code's largest
    /// request is a full context window plus attachments; 256 MB is far above that
    /// and still bounds our memory.
    static let maxBodyBytes = 256 * 1024 * 1024
    private static let maxHeaderBytes = 1024 * 1024

    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete request, or nil when more bytes are needed.
    mutating func next() throws -> Request? {
        guard let headerEnd = Self.range(of: Data("\r\n\r\n".utf8), in: buffer) else {
            if buffer.count > Self.maxHeaderBytes { throw ParseError.malformed("header too large") }
            return nil
        }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw ParseError.malformed("headers are not UTF-8")
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let startLine = lines.first else { throw ParseError.malformed("no request line") }
        lines.removeFirst()

        let startParts = startLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard startParts.count >= 2 else { throw ParseError.malformed("bad request line") }

        var headers: [(name: String, value: String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw ParseError.malformed("bad header line")
            }
            let name = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        var request = Request(method: startParts[0], target: startParts[1],
                             headers: headers, body: Data())
        let bodyStart = headerEnd.upperBound

        let chunked = request.header("Transfer-Encoding")?
            .range(of: "chunked", options: .caseInsensitive) != nil
        if chunked {
            guard let (body, end) = try Self.decodeChunked(buffer, from: bodyStart) else {
                return nil
            }
            request.body = body
            buffer.removeSubrange(buffer.startIndex..<end)
            return request
        }

        let length = Int(request.header("Content-Length") ?? "0") ?? 0
        guard length <= Self.maxBodyBytes else { throw ParseError.tooLarge }
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        request.body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return request
    }

    static func decodeChunked(_ data: Data, from start: Data.Index) throws
        -> (Data, Data.Index)? {
        var cursor = start
        var body = Data()
        while true {
            guard let lineEnd = range(of: Data("\r\n".utf8), in: data, from: cursor) else {
                return nil
            }
            let sizeText = String(decoding: data[cursor..<lineEnd.lowerBound], as: UTF8.self)
            let sizeField = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw ParseError.malformed("bad chunk size")
            }
            cursor = lineEnd.upperBound
            if size == 0 {
                // Trailers, then the final CRLF.
                guard let end = range(of: Data("\r\n".utf8), in: data, from: cursor) else {
                    return nil
                }
                return (body, end.upperBound)
            }
            guard body.count + size <= maxBodyBytes else { throw ParseError.tooLarge }
            guard data.distance(from: cursor, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(cursor, offsetBy: size)
            body.append(data[cursor..<chunkEnd])
            cursor = data.index(chunkEnd, offsetBy: 2)
        }
    }

    static func range(of needle: Data, in haystack: Data,
                      from start: Data.Index? = nil) -> Range<Data.Index>? {
        let lower = start ?? haystack.startIndex
        guard lower <= haystack.endIndex else { return nil }
        return haystack.range(of: needle, in: lower..<haystack.endIndex)
    }
}

enum HTTPResponseWriter {
    /// Headers a proxy must not copy through: they describe the hop, not the payload.
    /// Content-Encoding and Content-Length go too because URLSession hands us the
    /// decoded body and we re-frame it as chunked.
    static let strippedResponseHeaders: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade",
        "content-encoding", "content-length",
    ]

    /// Foundation's `localizedString(forStatusCode:)` returns things like "no error"
    /// for 200, which is not a reason phrase. Only the codes that actually reach a
    /// Claude Code client need naming; anything else gets a generic class phrase.
    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        case 100..<200: return "Informational"
        case 200..<300: return "Success"
        case 300..<400: return "Redirection"
        case 400..<500: return "Client Error"
        default: return "Server Error"
        }
    }

    static func head(status: Int, reason: String, headers: [(String, String)],
                     framing: String) -> Data {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers
        where !strippedResponseHeaders.contains(name.lowercased()) {
            text += "\(name): \(value)\r\n"
        }
        text += framing
        text += "\r\n"
        return Data(text.utf8)
    }

    static func chunk(_ data: Data) -> Data {
        var out = Data(String(format: "%llx\r\n", UInt64(data.count)).utf8)
        out.append(data)
        out.append(Data("\r\n".utf8))
        return out
    }

    static let terminator = Data("0\r\n\r\n".utf8)

    static func error(status: Int, reason: String, message: String) -> Data {
        let body = Data(message.utf8)
        var out = Data(("HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n").utf8)
        out.append(body)
        return out
    }
}
