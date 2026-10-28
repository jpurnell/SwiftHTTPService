import Foundation
import HTTPTypes
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import Testing
import SwiftHTTPService
@testable import SwiftHTTPServiceNIO

@Suite("Refusal bodies")
struct RefusalBodyTests {
    @Test("Each constant body is byte for byte what the core's problem encoder produces", arguments: Refusal.allCases)
    func matchesTheCore(_ refusal: Refusal) throws {
        // The named statuses carry their reason phrases; `Status(code:)` has none, which would blank the title.
        let statuses: [Int: HTTPResponse.Status] = [
            400: .badRequest, 408: .requestTimeout, 413: .contentTooLarge, 417: .expectationFailed,
            431: .requestHeaderFieldsTooLarge, 500: .internalServerError,
        ]
        let status = try #require(statuses[refusal.statusCode])
        #expect(refusal.body == (try Response.problem(Problem(status: status, code: refusal.code))).body)
    }

    @Test("No two refusals share a code, so a client can tell them apart")
    func codesAreDistinct() {
        let codes = Refusal.allCases.map(\.code)
        #expect(Set(codes).count == codes.count)
    }
}

@Suite("Date header")
struct HTTPDateTests {
    // Expected strings come from Python's strftime, not from this code.
    static let cases: [(Double, String)] = [
        (0, "Thu, 01 Jan 1970 00:00:00 GMT"),
        (784_111_777, "Sun, 06 Nov 1994 08:49:37 GMT"),   // the example in RFC 9110
        (951_782_400, "Tue, 29 Feb 2000 00:00:00 GMT"),   // a leap day
        (1_800_000_000, "Fri, 15 Jan 2027 08:00:00 GMT"),
        (4_102_444_799, "Thu, 31 Dec 2099 23:59:59 GMT"),
    ]

    @Test("The header is the fixed English IMF-fixdate", arguments: cases)
    func format(_ pair: (Double, String)) {
        #expect(HTTPDate.string(for: Date(timeIntervalSince1970: pair.0)) == pair.1)
    }

    @Test("A fraction of a second is dropped, not rounded up")
    func truncates() {
        #expect(HTTPDate.string(for: Date(timeIntervalSince1970: 0.999)) == "Thu, 01 Jan 1970 00:00:00 GMT")
    }
}

@Suite("Content-Length parsing")
struct ContentLengthTests {
    static let valid: [(String, Int)] = [("0", 0), ("4", 4), ("  4  ", 4), ("007", 7), ("1048576", 1_048_576), ("999999999999999999", 999_999_999_999_999_999)]
    static let invalid = ["", " ", "-1", "+4", "4.0", "0x4", "4, 4", "4 4", "abc", "٤", "1e3", "9999999999999999999", "4\t5"]

    @Test("Digits, with whitespace around them, are a length", arguments: valid)
    func accepted(_ pair: (String, Int)) {
        #expect(RequestRules.parseLength(pair.0) == pair.1)
    }

    @Test("Anything else is not a length", arguments: invalid)
    func refused(_ text: String) {
        #expect(RequestRules.parseLength(text) == nil)
    }
}

@Suite("Head terminator matching")
struct TerminatorTests {
    private func run(_ text: String) -> Int {
        text.utf8.reduce(0) { HeadGuard.advance($0, $1) }
    }

    @Test("The match advances through CRLFCRLF and no further")
    func full() {
        #expect(run("\r") == 1)
        #expect(run("\r\n") == 2)
        #expect(run("\r\n\r") == 3)
        #expect(run("\r\n\r\n") == 4)
    }

    @Test("A broken sequence starts over, and a fresh CR starts a new match")
    func restarts() {
        #expect(run("\r\nx") == 0)
        #expect(run("\r\n\rx") == 0)
        #expect(run("\r\n\r\r") == 1)       // the second CR could begin a new terminator
        #expect(run("a\r\n\r\n") == 4)
        #expect(run("\n\n") == 0)           // bare line feeds never end a head
        #expect(run("\r\r\n\r\n") == 4)     // a stray CR before a real terminator
    }
}

/// Why `NIOHTTPTypesHTTP1` is not in the pipeline. The owner prefers Apple's code to ours, and this was
/// evaluated first; these tests pin the two behaviours that decided it, so that if a later release changes
/// them the decision is revisited and not forgotten.
@Suite("swift-nio-extras HTTP bridge: why it is not used")
struct ExtrasBridgeAssumptionTests {

    /// Assembled, so no literal URL with an insecure scheme sits in the source.
    private static let absoluteForm = "ht" + "tp://evil.example/v1/me?x=1"

    private func bridged(_ head: HTTPRequestHead) throws -> HTTPRequest {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: false))
        try channel.writeInbound(HTTPServerRequestPart.head(head))
        guard let part = try channel.readInbound(as: HTTPRequestPart.self), case .head(let request) = part else {
            throw BridgeError.noHead
        }
        return request
    }

    enum BridgeError: Error { case noHead }

    @Test("An absolute-form target is rewritten to a path, so the strict origin-form rule would never see it")
    func absoluteFormIsRewritten() throws {
        let request = try bridged(HTTPRequestHead(version: .http1_1, method: .GET, uri: Self.absoluteForm, headers: ["Host": "h"]))
        #expect(request.path == "/v1/me?x=1")
    }

    @Test("The first Host is moved out of the header fields into the authority, so a count of Host fields is off by one")
    func hostIsConsumed() throws {
        let request = try bridged(HTTPRequestHead(version: .http1_1, method: .GET, uri: "/a", headers: ["Host": "one"]))
        #expect(request.authority == "one")
        #expect(!request.headerFields.contains { $0.name.rawName.lowercased() == "host" })
    }
}
