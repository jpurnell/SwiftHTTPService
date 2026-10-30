import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// The `Host` allow-list: a request for a name nobody listed is a `421`, before anything else runs.
@Suite("Allowed hosts")
struct AllowedHostsTests {

    private actor Calls {
        var count = 0
        func hit() { count += 1 }
    }

    private static func request(hosts: [String]) throws -> Request {
        var headers = HTTPFields()
        for host in hosts { headers.append(HTTPField(name: .hostField,value: host)) }
        return try Request(method: .get, target: "/x", headers: headers, body: Data())
    }

    private static func run(_ allowed: [String], hosts: [String]) async throws -> (Response, Int) {
        let calls = Calls()
        let layer = try allowedHosts(allowed)
        let response = try await layer(try request(hosts: hosts)) { _ in
            await calls.hit()
            return Response(status: .ok, body: Data("through".utf8))
        }
        return (response, await calls.count)
    }

    // MARK: Construction

    @Test("An empty list is refused")
    func emptyList() {
        #expect(throws: AllowedHostsError.noEntries) { try allowedHosts([]) }
    }

    struct Bad: Sendable, CustomTestStringConvertible {
        let entry: String
        var testDescription: String { entry.debugDescription }
    }

    // Each is wrong for a reason named in the rules: empty, whitespace, control character, path, scheme, userinfo,
    // a wildcard or list, a malformed port, a malformed bracket, a byte outside visible ASCII.
    static let badEntries: [Bad] = [
        "", " ", "local host", " localhost", "localhost ", "localhost\t", "local\thost", "localhost\r\nX: y", "a\u{0}b", "a\u{7F}b",
        "http://localhost", "https://localhost:8443", "localhost/", "localhost/x", "localhost?x=1", "localhost#f", "//localhost",
        "user@localhost", "localhost@evil", "*", "*.example", "a,b", "a;b", "a\\b",
        "localhost:", ":8080", "localhost:0", "localhost:65536", "localhost:99999", "localhost:123456", "localhost:08080",
        "localhost:80a", "localhost:-1", "localhost:+1", "a:b:c", "::1", "::1:8080",
        "[::1", "[]", "[]:8080", "[::1]x", "[::1]:", "[zz]", "[::1]:99999", "[::1]]", "[[::1]]", "[abc]", "[1.2.3.4]", "[:g]",
        "caf\u{E9}.example", "\u{212A}elvin", "..", "a..b", ".a", "a.", "localhost.", "a.:80", "a b:80",
    ].map(Bad.init)

    @Test("Each malformed entry is refused, naming its position and never its value", arguments: badEntries)
    func malformed(_ bad: Bad) {
        #expect(throws: AllowedHostsError.invalidEntry(at: 1)) { try allowedHosts(["localhost", bad.entry]) }
    }

    @Test("Well-formed entries are accepted: names, names with ports, IPv4, bracketed IPv6, mixed case, underscore")
    func wellFormed() throws {
        for entry in ["localhost", "localhost:8080", "127.0.0.1:9000", "127.0.0.1", "[::1]:8080", "[::1]", "Example.COM", "my_host:1", "a:65535", "x-y.z"] {
            #expect(throws: Never.self, "\(entry)") { try allowedHosts([entry]) }
        }
    }

    @Test("The first bad entry's position is named, not the last")
    func position() {
        #expect(throws: AllowedHostsError.invalidEntry(at: 2)) { try allowedHosts(["a", "b", "c d", "e f"]) }
    }

    // MARK: Matching

    struct Case: Sendable, CustomTestStringConvertible {
        let allowed: [String]
        let host: String
        let permitted: Bool
        var testDescription: String { "\(allowed) vs \(host.debugDescription)" }
    }

    static let cases: [Case] = [
        // host and port, exact
        Case(allowed: ["localhost:8080"], host: "localhost:8080", permitted: true),
        Case(allowed: ["localhost:8080"], host: "localhost:8081", permitted: false),
        Case(allowed: ["localhost:8080"], host: "localhost", permitted: false),
        Case(allowed: ["localhost:8080"], host: "localhost:80800", permitted: false),
        Case(allowed: ["localhost:8080"], host: "localhost:808", permitted: false),
        Case(allowed: ["localhost:8080"], host: "localhost.:8080", permitted: false),
        Case(allowed: ["localhost:8080"], host: "xlocalhost:8080", permitted: false),
        Case(allowed: ["localhost:8080"], host: "localhost:8080x", permitted: false),
        Case(allowed: ["localhost:8080"], host: "evil.localhost:8080", permitted: false),
        Case(allowed: ["localhost:8080"], host: "localhost:8080, evil.example", permitted: false),
        Case(allowed: ["localhost:8080"], host: "localhost:8080@evil.example", permitted: false),
        Case(allowed: ["localhost:8080"], host: "evil.example:8080@localhost:8080", permitted: false),
        Case(allowed: ["localhost:8080"], host: "", permitted: false),
        // a bare host admits only a Host without a port
        Case(allowed: ["localhost"], host: "localhost", permitted: true),
        Case(allowed: ["localhost"], host: "localhost:80", permitted: false),
        Case(allowed: ["localhost"], host: "localhost:", permitted: false),
        // case-insensitive, both ways
        Case(allowed: ["localhost:8080"], host: "LOCALHOST:8080", permitted: true),
        Case(allowed: ["LocalHost:8080"], host: "localhost:8080", permitted: true),
        Case(allowed: ["LocalHost:8080"], host: "lOcAlHoSt:8080", permitted: true),
        // only ASCII case is folded: the Kelvin sign is not a K
        Case(allowed: ["kelvin"], host: "\u{212A}elvin", permitted: false),
        Case(allowed: ["kelvin"], host: "KELVIN", permitted: true),
        Case(allowed: ["zone", "a"], host: "ZONE", permitted: true),
        Case(allowed: ["ZONE", "A"], host: "zone", permitted: true),
        Case(allowed: ["zone"], host: "zon", permitted: false),
        // IP literals
        Case(allowed: ["127.0.0.1:9000"], host: "127.0.0.1:9000", permitted: true),
        Case(allowed: ["127.0.0.1:9000"], host: "127.0.0.2:9000", permitted: false),
        Case(allowed: ["[::1]:8080"], host: "[::1]:8080", permitted: true),
        Case(allowed: ["[::1]:8080"], host: "[::1]", permitted: false),
        Case(allowed: ["[::1]:8080"], host: "[::2]:8080", permitted: false),
        Case(allowed: ["[::1]"], host: "[::1]", permitted: true),
        Case(allowed: ["[::A]:1"], host: "[::a]:1", permitted: true),
        // several entries: any one admits
        Case(allowed: ["a.example:1", "b.example:2"], host: "b.example:2", permitted: true),
        Case(allowed: ["a.example:1", "b.example:2"], host: "a.example:2", permitted: false),
        Case(allowed: ["a.example:1", "b.example:2"], host: "c.example:1", permitted: false),
    ]

    @Test("Host matching follows the rule for each case", arguments: cases)
    func matching(_ testCase: Case) async throws {
        let (response, calls) = try await Self.run(testCase.allowed, hosts: [testCase.host])
        #expect((response.status == .ok) == testCase.permitted)
        #expect(calls == (testCase.permitted ? 1 : 0))
        if testCase.permitted {
            #expect(response.body == Data("through".utf8))
        } else {
            #expect(response.status.code == 421)
        }
    }

    @Test("No Host at all is a 421; so are two Host fields, even if both are allowed")
    func missingOrRepeated() async throws {
        let (none, noneCalls) = try await Self.run(["localhost:8080"], hosts: [])
        #expect(none.status.code == 421)
        #expect(noneCalls == 0)
        let (twice, twiceCalls) = try await Self.run(["localhost:8080"], hosts: ["localhost:8080", "localhost:8080"])
        #expect(twice.status.code == 421)
        #expect(twiceCalls == 0)
    }

    @Test("The refusal is the kit's fixed problem body, with a content type, and says nothing about the request")
    func refusalShape() async throws {
        let (response, _) = try await Self.run(["localhost:8080"], hosts: ["evil.example:8080"])
        #expect(response.status.code == 421)
        #expect(response.headers[.contentType] == "application/problem+json")
        #expect(response.body == Data(#"{"code":"misdirected_request","status":421,"title":"Misdirected Request","type":"about:blank"}"#.utf8))
        #expect(!String(decoding: response.body, as: UTF8.self).contains("evil"))
    }

    @Test("A request that is allowed gets the handler's response untouched")
    func untouched() async throws {
        let layer = try allowedHosts(["localhost:8080"])
        var headers = HTTPFields()
        headers[.eTag] = "\"v1\""
        let expected = Response(status: .accepted, headers: headers, body: Data("x".utf8))
        let response = try await layer(try Self.request(hosts: ["localhost:8080"])) { _ in expected }
        #expect(response == expected)
    }

    @Test("An error the handler throws is not caught")
    func handlerErrorPropagates() async throws {
        struct Boom: Error {}
        let layer = try allowedHosts(["localhost:8080"])
        await #expect(throws: Boom.self) {
            _ = try await layer(try Self.request(hosts: ["localhost:8080"])) { _ in throw Boom() }
        }
    }
}
