import Foundation
import Testing
@testable import CCMuxCore
@testable import CCMuxKit

@Suite("Proxy HTTP framing")
struct HTTPMessageTests {
    @Test func parsesTheRequestClaudeCodeActuallySends() throws {
        var parser = HTTPRequestParser()
        let body = #"{"model":"claude-sonnet-5"}"#
        parser.append(Data("""
        POST /v1/messages?beta=true HTTP/1.1\r
        Host: 127.0.0.1:8899\r
        Authorization: Bearer sk-ant-oat01-secret\r
        anthropic-beta: claude-code-20250219,oauth-2025-04-20\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """.utf8))
        let request = try #require(try parser.next())
        #expect(request.method == "POST")
        #expect(request.target == "/v1/messages?beta=true")
        #expect(request.header("authorization") == "Bearer sk-ant-oat01-secret")
        #expect(String(decoding: request.body, as: UTF8.self) == body)
        #expect(request.wantsKeepAlive)
    }

    @Test func returnsNilUntilTheBodyIsComplete() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /v1/messages HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data("cde".utf8))
        let request = try #require(try parser.next())
        #expect(String(decoding: request.body, as: UTF8.self) == "abcde")
    }

    @Test func returnsNilUntilHeadersAreComplete() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("HEAD /api/hello HTTP/1.1\r\nHost: x\r\n".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data("\r\n".utf8))
        let request = try #require(try parser.next())
        #expect(request.method == "HEAD")
        #expect(request.target == "/api/hello")
        #expect(request.body.isEmpty)
    }

    /// Keep-alive means two requests can arrive in one read; dropping the second would
    /// hang the session.
    @Test func parsesPipelinedRequests() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("""
        HEAD /api/hello HTTP/1.1\r
        Host: x\r
        \r
        POST /v1/messages HTTP/1.1\r
        Content-Length: 2\r
        \r
        hi
        """.utf8))
        let first = try #require(try parser.next())
        #expect(first.target == "/api/hello")
        let second = try #require(try parser.next())
        #expect(second.target == "/v1/messages")
        #expect(String(decoding: second.body, as: UTF8.self) == "hi")
        #expect(try parser.next() == nil)
    }

    @Test func decodesChunkedRequestBody() throws {
        var parser = HTTPRequestParser()
        parser.append(Data(("POST /v1/messages HTTP/1.1\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "\r\n"
            + "4\r\nabcd\r\n"
            + "3\r\nefg\r\n"
            + "0\r\n\r\n").utf8))
        let request = try #require(try parser.next())
        #expect(String(decoding: request.body, as: UTF8.self) == "abcdefg")
    }

    @Test func chunkExtensionsAreIgnored() throws {
        var parser = HTTPRequestParser()
        parser.append(Data(("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "4;name=value\r\nabcd\r\n0\r\n\r\n").utf8))
        let request = try #require(try parser.next())
        #expect(String(decoding: request.body, as: UTF8.self) == "abcd")
    }

    @Test func incompleteChunkedBodyWaits() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nab".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data("cd\r\n0\r\n\r\n".utf8))
        let request = try #require(try parser.next())
        #expect(String(decoding: request.body, as: UTF8.self) == "abcd")
    }

    @Test func connectionCloseIsHonoured() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("GET /x HTTP/1.1\r\nConnection: close\r\n\r\n".utf8))
        let request = try #require(try parser.next())
        #expect(!request.wantsKeepAlive)
    }

    @Test func malformedRequestThrows() {
        var parser = HTTPRequestParser()
        parser.append(Data("GARBAGE\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.ParseError.self) { try parser.next() }
    }

    /// Copying these through would make the client re-decode an already-decoded body
    /// or wait for bytes that never come.
    @Test func hopByHopAndEncodingHeadersAreStripped() {
        let head = String(decoding: HTTPResponseWriter.head(
            status: 200, reason: "OK",
            headers: [("Content-Type", "text/event-stream"),
                      ("Content-Encoding", "gzip"),
                      ("Content-Length", "1234"),
                      ("Transfer-Encoding", "chunked"),
                      ("Connection", "keep-alive"),
                      ("anthropic-ratelimit-unified-5h-utilization", "0.35")],
            framing: "Transfer-Encoding: chunked\r\n"), as: UTF8.self)

        #expect(head.contains("HTTP/1.1 200 OK\r\n"))
        #expect(head.contains("Content-Type: text/event-stream\r\n"))
        #expect(head.contains("anthropic-ratelimit-unified-5h-utilization: 0.35\r\n"))
        #expect(!head.lowercased().contains("content-encoding"))
        #expect(!head.contains("Content-Length: 1234"))
        #expect(head.hasSuffix("Transfer-Encoding: chunked\r\n\r\n"))
        // Exactly one framing header, or the client cannot tell where the body ends.
        #expect(head.components(separatedBy: "Transfer-Encoding").count == 2)
    }

    @Test func chunkFramingIsHexLengthPrefixed() {
        #expect(String(decoding: HTTPResponseWriter.chunk(Data("hello".utf8)), as: UTF8.self)
                == "5\r\nhello\r\n")
        #expect(String(decoding: HTTPResponseWriter.chunk(Data(repeating: 0x61, count: 255)),
                       as: UTF8.self).hasPrefix("ff\r\n"))
        #expect(String(decoding: HTTPResponseWriter.terminator, as: UTF8.self) == "0\r\n\r\n")
    }
}

@Suite("Reason phrases")
struct ReasonPhraseTests {
    /// Foundation returns "no error" for 200, which is not a reason phrase; a client
    /// reading the status line should see something sane.
    @Test func commonStatusesGetRealPhrases() {
        #expect(HTTPResponseWriter.reasonPhrase(200) == "OK")
        #expect(HTTPResponseWriter.reasonPhrase(429) == "Too Many Requests")
        #expect(HTTPResponseWriter.reasonPhrase(503) == "Service Unavailable")
    }

    @Test func unknownStatusesFallBackToTheirClass() {
        #expect(HTTPResponseWriter.reasonPhrase(207) == "Success")
        #expect(HTTPResponseWriter.reasonPhrase(451) == "Client Error")
        #expect(HTTPResponseWriter.reasonPhrase(599) == "Server Error")
    }
}

@Suite("Chunked framing edge cases")
struct ChunkedFramingTests {
    /// The bug: only the first line after the terminal chunk was consumed, so a trailer
    /// left a stray CRLF that made the next pipelined request parse as a bad start line.
    @Test func trailersAreConsumedSoTheNextRequestStillParses() throws {
        var parser = HTTPRequestParser()
        parser.append(Data(("POST /v1/messages HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "4\r\nabcd\r\n"
            + "0\r\n"
            + "X-Checksum: deadbeef\r\n"
            + "\r\n"
            + "HEAD /api/hello HTTP/1.1\r\nHost: x\r\n\r\n").utf8))

        let first = try #require(try parser.next())
        #expect(String(decoding: first.body, as: UTF8.self) == "abcd")
        let second = try #require(try parser.next())
        #expect(second.method == "HEAD")
        #expect(second.target == "/api/hello")
    }

    @Test func terminalChunkWithNoTrailersIsFine() throws {
        var parser = HTTPRequestParser()
        parser.append(Data(("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "2\r\nhi\r\n0\r\n\r\n"
            + "GET /y HTTP/1.1\r\n\r\n").utf8))
        #expect(String(decoding: try #require(try parser.next()).body, as: UTF8.self) == "hi")
        #expect(try #require(try parser.next()).target == "/y")
    }

    /// Chunks arriving one byte at a time must decode to the same body, and must not be
    /// re-decoded from the start on every read.
    @Test func chunksDecodeAcrossArbitrarySplits() throws {
        let wire = "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n1\r\n \r\n5\r\nworld\r\n0\r\n\r\n"
        var parser = HTTPRequestParser()
        var result: HTTPRequestParser.Request?
        for byte in Array(wire.utf8) {
            parser.append(Data([byte]))
            if let request = try parser.next() { result = request }
        }
        #expect(String(decoding: try #require(result).body, as: UTF8.self) == "hello world")
    }

    @Test func bodyArrivingInPiecesIsAssembledOnce() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /x HTTP/1.1\r\nContent-Length: 9\r\n\r\n".utf8))
        #expect(try parser.next() == nil)
        for piece in ["abc", "def", "ghi"] {
            parser.append(Data(piece.utf8))
        }
        #expect(String(decoding: try #require(try parser.next()).body, as: UTF8.self)
                == "abcdefghi")
    }

    @Test func headerLookupIsCaseInsensitive() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("GET /x HTTP/1.1\r\nCoNtEnT-LeNgTh: 0\r\nX-App: cli\r\n\r\n".utf8))
        let request = try #require(try parser.next())
        #expect(request.header("content-length") == "0")
        #expect(request.header("X-APP") == "cli")
        #expect(request.header("absent") == nil)
    }

    @Test func aRequestLineWithoutAPathIsRejected() {
        var parser = HTTPRequestParser()
        parser.append(Data("POST notapath HTTP/1.1\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.ParseError.self) { try parser.next() }
    }
}

@Suite("Malformed framing is refused, not fatal")
struct MalformedFramingTests {
    /// A negative Content-Length reached `Data.prefix`, which traps — so one malformed
    /// request to a session's loopback port killed the app and every other session's
    /// proxy with it.
    @Test func negativeContentLengthIsRejected() {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /v1/messages HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.ParseError.self) { try parser.next() }
    }

    @Test func nonNumericContentLengthIsRejected() {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /x HTTP/1.1\r\nContent-Length: eight\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.ParseError.self) { try parser.next() }
    }

    @Test func anAbsurdContentLengthIsRefusedRatherThanBuffered() {
        var parser = HTTPRequestParser()
        parser.append(Data("POST /x HTTP/1.1\r\nContent-Length: 999999999999\r\n\r\n".utf8))
        #expect(throws: HTTPRequestParser.ParseError.tooLarge) { try parser.next() }
    }

    @Test func negativeChunkSizeIsRejected() {
        var parser = HTTPRequestParser()
        parser.append(Data(("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "-4\r\nabcd\r\n").utf8))
        #expect(throws: HTTPRequestParser.ParseError.self) { try parser.next() }
    }
}
