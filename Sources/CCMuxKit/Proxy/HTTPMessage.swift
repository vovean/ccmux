import CCMuxCore
import Foundation

/// Incremental HTTP/1.1 request parser for the proxy's inbound leg.
///
/// Stateful on purpose. A parser that re-derived everything from the start of the
/// buffer on each socket read would re-parse the head — and re-copy every chunk of a
/// chunked body — once per read, which for a multi-megabyte request is dozens of
/// redundant passes.
///
/// Only what a Claude Code client actually sends has to work: an absolute-path request
/// line, CRLF-terminated headers, and a body framed by Content-Length or chunked
/// transfer coding.
struct HTTPRequestParser {
    struct Request {
        var method: String
        var target: String
        var headers: [(name: String, value: String)]
        /// Lower-cased index over `headers`, built once with the head.
        var folded: [String: String]
        var body: Data

        func header(_ name: String) -> String? { folded[name.lowercased()] }

        var wantsKeepAlive: Bool {
            (header("connection") ?? "keep-alive").caseInsensitiveCompare("close")
                != .orderedSame
        }
    }

    enum ParseError: Error, Equatable {
        case malformed(String)
        case tooLarge
    }

    /// Bodies above this are refused rather than buffered. Claude Code's largest request
    /// is a full context window plus attachments; 256 MB is far above that and still
    /// bounds our memory.
    static let maxBodyBytes = 256 * 1024 * 1024
    private static let maxHeaderBytes = 1024 * 1024
    private static let crlf = Data("\r\n".utf8)
    private static let headEnd = Data("\r\n\r\n".utf8)

    private enum State {
        case awaitingHead
        case awaitingBody(head: Request, remaining: Int)
        case awaitingChunks(head: Request, decoded: Data)
    }

    private var buffer = Data()
    private var state = State.awaitingHead

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete request, or nil when more bytes are needed.
    mutating func next() throws -> Request? {
        while true {
            switch state {
            case .awaitingHead:
                guard let head = try parseHead() else { return nil }
                if head.header("transfer-encoding")?
                    .range(of: "chunked", options: .caseInsensitive) != nil {
                    state = .awaitingChunks(head: head, decoded: Data())
                    continue
                }
                let field = head.header("content-length") ?? "0"
                guard let length = Int(field), length >= 0 else {
                    throw ParseError.malformed("bad content-length: \(field)")
                }
                guard length <= Self.maxBodyBytes else { throw ParseError.tooLarge }
                if length == 0 {
                    state = .awaitingHead
                    return head
                }
                state = .awaitingBody(head: head, remaining: length)

            case .awaitingBody(var head, let remaining):
                guard buffer.count >= remaining else { return nil }
                // Hand the storage over rather than copying a body the buffer already
                // holds, and drop the buffer's grown capacity between requests.
                head.body = Data(buffer.prefix(remaining))
                buffer = Data(buffer.dropFirst(remaining))
                state = .awaitingHead
                return head

            case .awaitingChunks(var head, var decoded):
                switch try consumeChunks(into: &decoded) {
                case .needMore:
                    state = .awaitingChunks(head: head, decoded: decoded)
                    return nil
                case .complete:
                    head.body = decoded
                    state = .awaitingHead
                    return head
                }
            }
        }
    }

    private mutating func parseHead() throws -> Request? {
        guard let terminator = buffer.range(of: Self.headEnd) else {
            if buffer.count > Self.maxHeaderBytes {
                throw ParseError.malformed("header too large")
            }
            return nil
        }
        guard let text = String(data: buffer[buffer.startIndex..<terminator.lowerBound],
                                encoding: .utf8) else {
            throw ParseError.malformed("headers are not UTF-8")
        }
        buffer = Data(buffer[terminator.upperBound...])

        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw ParseError.malformed("no request line") }
        let start = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard start.count >= 2, !start[0].isEmpty, start[1].hasPrefix("/") else {
            throw ParseError.malformed("bad request line")
        }

        var headers: [(name: String, value: String)] = []
        var folded: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw ParseError.malformed("bad header line")
            }
            let name = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
            folded[name.lowercased()] = value
        }
        return Request(method: start[0], target: start[1], headers: headers, folded: folded,
                      body: Data())
    }

    private enum ChunkProgress { case needMore, complete }

    /// Consumes whole chunks from the front of the buffer, resuming where the previous
    /// call stopped rather than re-decoding from the body start.
    private mutating func consumeChunks(into decoded: inout Data) throws -> ChunkProgress {
        while true {
            guard let lineEnd = buffer.range(of: Self.crlf) else { return .needMore }
            let sizeText = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound],
                                  as: UTF8.self)
            let sizeField = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16),
                  size >= 0 else {
                throw ParseError.malformed("bad chunk size")
            }

            if size == 0 {
                // Trailers may follow the terminal chunk; consume lines until the blank
                // one, or the leftover bytes would corrupt the next pipelined request.
                var cursor = lineEnd.upperBound
                while true {
                    guard let trailerEnd = buffer.range(of: Self.crlf,
                                                        in: cursor..<buffer.endIndex) else {
                        return .needMore
                    }
                    let isBlank = trailerEnd.lowerBound == cursor
                    cursor = trailerEnd.upperBound
                    if isBlank { break }
                }
                buffer = Data(buffer[cursor...])
                return .complete
            }

            guard decoded.count + size <= Self.maxBodyBytes else { throw ParseError.tooLarge }
            // Do not consume the size line until its data has arrived, or the resumed
            // call would look for a size line where chunk data is.
            let dataStart = lineEnd.upperBound
            guard buffer.distance(from: dataStart, to: buffer.endIndex) >= size + 2 else {
                return .needMore
            }
            let dataEnd = buffer.index(dataStart, offsetBy: size)
            decoded.append(buffer[dataStart..<dataEnd])
            buffer = Data(buffer[buffer.index(dataEnd, offsetBy: 2)...])
        }
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

    /// Foundation's `localizedString(forStatusCode:)` returns things like "no error" for
    /// 200, which is not a reason phrase. Only the codes that actually reach a Claude
    /// Code client need naming; anything else gets a generic class phrase.
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
        var out = Data(String(data.count, radix: 16).utf8)
        out.append(Data("\r\n".utf8))
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
