import Foundation
import Testing
@testable import SwiftHTTPServiceNIO

/// The PROXY protocol header (HAProxy's specification, version 1 as text and version 2 as binary), parsed as a pure
/// function of the bytes received so far: not enough yet, a header, or something that is not one. Expected values
/// are worked out by hand from that specification.
@Suite("PROXY protocol header")
struct ProxyHeaderTests {

    private static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// A version 2 header: the 12-byte signature, version and command, family and protocol, a length, the body.
    private static func v2(command: UInt8 = 0x21, family: UInt8 = 0x11, body: [UInt8], length: Int? = nil) -> [UInt8] {
        let signature: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A]
        let size = length ?? body.count
        return signature + [command, family, UInt8(size >> 8), UInt8(size & 0xFF)] + body
    }

    private static let ipv4Body: [UInt8] = [203, 0, 113, 9] + [192, 0, 2, 1] + [0x15, 0xB3] + [0x01, 0xBB]       // 203.0.113.9 -> 192.0.2.1, ports 5555 and 443
    private static var ipv6Body: [UInt8] {
        [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x09] + [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01] + [0x15, 0xB3, 0x01, 0xBB]
    }

    struct Good: Sendable, CustomTestStringConvertible {
        let name: String
        let input: [UInt8]
        let client: String?
        let consumed: Int
        var testDescription: String { name }
    }

    static let good: [Good] = [
        Good(name: "v1 TCP4", input: bytes("PROXY TCP4 203.0.113.9 192.0.2.1 5555 443\r\n"), client: "203.0.113.9", consumed: 43),
        Good(name: "v1 TCP4 with an HTTP request after it", input: bytes("PROXY TCP4 203.0.113.9 192.0.2.1 5555 443\r\nGET / HTTP/1.1\r\n"), client: "203.0.113.9", consumed: 43),
        Good(name: "v1 TCP6", input: bytes("PROXY TCP6 2001:db8::9 2001:db8::1 5555 443\r\n"), client: "2001:db8::9", consumed: 45),
        Good(name: "v1 TCP6 written in capitals is canonical lower case", input: bytes("PROXY TCP6 2001:DB8::9 2001:db8::1 1 2\r\n"), client: "2001:db8::9", consumed: 40),
        Good(name: "v1 port 0 and 65535", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 0 65535\r\n"), client: "1.2.3.4", consumed: 36),
        Good(name: "v1 UNKNOWN has no client", input: bytes("PROXY UNKNOWN\r\n"), client: nil, consumed: 15),
        Good(name: "v1 UNKNOWN ignores what follows on the line", input: bytes("PROXY UNKNOWN ffff::1 ffff::2 1 2\r\nrest"), client: nil, consumed: 35),
        Good(name: "v2 PROXY IPv4", input: v2(body: ipv4Body), client: "203.0.113.9", consumed: 28),
        Good(name: "v2 PROXY IPv6", input: v2(family: 0x21, body: ipv6Body), client: "2001:db8::9", consumed: 52),
        Good(name: "v2 PROXY IPv4 with trailing TLVs skipped", input: v2(body: ipv4Body + [0x04, 0x00, 0x02, 0xAA, 0xBB]), client: "203.0.113.9", consumed: 33),
        Good(name: "v2 followed by an HTTP request", input: v2(body: ipv4Body) + bytes("GET / HTTP/1.1\r\n"), client: "203.0.113.9", consumed: 28),
        Good(name: "v2 LOCAL has no client, whatever follows", input: v2(command: 0x20, family: 0x00, body: []), client: nil, consumed: 16),
        Good(name: "v2 LOCAL with an address block is still no client", input: v2(command: 0x20, body: ipv4Body), client: nil, consumed: 28),
        Good(name: "v2 UNSPEC family has no client", input: v2(family: 0x00, body: [1, 2, 3]), client: nil, consumed: 19),
        Good(name: "v2 UNIX family has no client", input: v2(family: 0x31, body: [UInt8](repeating: 0, count: 216)), client: nil, consumed: 232),
        Good(name: "v2 datagram protocol has no client", input: v2(family: 0x12, body: ipv4Body), client: nil, consumed: 28),
        Good(name: "v2 IPv4-mapped IPv6 client is its IPv4 self", input: v2(family: 0x21, body: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 203, 0, 113, 9] + [UInt8](repeating: 1, count: 16) + [0, 1, 0, 2]), client: "203.0.113.9", consumed: 52),
    ]

    @Test("A header is read from the front of the bytes, saying who the client is and how many bytes it used", arguments: good)
    func parses(_ c: Good) {
        guard case .header(let client, let consumed) = ProxyHeader.parse(c.input) else {
            Issue.record("not a header: \(ProxyHeader.parse(c.input))")
            return
        }
        #expect(client == c.client)
        #expect(consumed == c.consumed)
    }

    @Test("Any strict prefix of a valid header is not enough yet, never a refusal, so a header arriving in pieces is read", arguments: good)
    func prefixes(_ c: Good) {
        for length in 0..<c.consumed {
            let outcome = ProxyHeader.parse(Array(c.input[0..<length]))
            #expect(outcome == .needMore, "\(length) of \(c.consumed) bytes: \(outcome)")
        }
    }

    struct Bad: Sendable, CustomTestStringConvertible {
        let name: String
        let input: [UInt8]
        var testDescription: String { name }
    }

    static let bad: [Bad] = [
        Bad(name: "lower-case keyword", input: bytes("proxy TCP4 1.2.3.4 5.6.7.8 1 2\r\n")),
        Bad(name: "something else beginning with P", input: bytes("PRI * HTTP/2.0\r\n")),
        Bad(name: "an HTTP request", input: bytes("GET / HTTP/1.1\r\n")),
        Bad(name: "a TLS hello", input: [0x16, 0x03, 0x01, 0x00, 0x30]),
        Bad(name: "a v2 signature with one wrong byte", input: [0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0B] + [0x21, 0x11, 0, 12]),
        Bad(name: "an unknown transport", input: bytes("PROXY UDP4 1.2.3.4 5.6.7.8 1 2\r\n")),
        Bad(name: "two spaces", input: bytes("PROXY TCP4  1.2.3.4 5.6.7.8 1 2\r\n")),
        Bad(name: "a trailing space", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 1 2 \r\n")),
        Bad(name: "too few fields", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 1\r\n")),
        Bad(name: "too many fields", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 1 2 3\r\n")),
        Bad(name: "a line feed without its carriage return", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 1 2\n")),
        Bad(name: "a carriage return not followed by a line feed", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 1 2\rX")),
        Bad(name: "a DEL byte in an UNKNOWN line", input: bytes("PROXY UNKNOWN \u{7F}\r\n")),
        Bad(name: "a control byte in an UNKNOWN line", input: bytes("PROXY UNKNOWN \u{1}\r\n")),
        Bad(name: "a non-ASCII byte in an UNKNOWN line", input: bytes("PROXY UNKNOWN \u{E9}\r\n")),
        Bad(name: "a line feed alone inside an UNKNOWN line", input: bytes("PROXY UNKNOWN a\nb\r\n")),
        Bad(name: "an IPv6 address on TCP4", input: bytes("PROXY TCP4 2001:db8::9 192.0.2.1 1 2\r\n")),
        Bad(name: "an IPv4 address on TCP6", input: bytes("PROXY TCP6 1.2.3.4 2001:db8::1 1 2\r\n")),
        Bad(name: "an IPv4-mapped address on TCP4", input: bytes("PROXY TCP4 ::ffff:1.2.3.4 5.6.7.8 1 2\r\n")),
        Bad(name: "an address with a leading zero", input: bytes("PROXY TCP4 01.2.3.4 5.6.7.8 1 2\r\n")),
        Bad(name: "an address that is not one", input: bytes("PROXY TCP4 1.2.3.256 5.6.7.8 1 2\r\n")),
        Bad(name: "a destination that is not an address", input: bytes("PROXY TCP4 1.2.3.4 host 1 2\r\n")),
        Bad(name: "port 65536", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 65536 2\r\n")),
        Bad(name: "a port with a leading zero", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 01 2\r\n")),
        Bad(name: "a negative port", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 -1 2\r\n")),
        Bad(name: "a port that is not a number", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 1 x\r\n")),
        Bad(name: "a control byte in the line", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 1 2\u{1}\r\n")),
        Bad(name: "a non-ASCII byte in the line", input: bytes("PROXY TCP4 1.2.3.4 5.6.7.8 1 \u{E9}\r\n")),
        Bad(name: "a line over 107 bytes with no end", input: bytes("PROXY UNKNOWN " + String(repeating: "a", count: 94))),
        Bad(name: "a line that ends only after 107 bytes", input: bytes("PROXY UNKNOWN " + String(repeating: "a", count: 94) + "\r\n")),
        Bad(name: "v2 with version 1", input: v2(command: 0x11, body: ipv4Body)),
        Bad(name: "v2 with version 3", input: v2(command: 0x31, body: ipv4Body)),
        Bad(name: "v2 with an unknown command", input: v2(command: 0x22, body: ipv4Body)),
        Bad(name: "v2 with an unknown transport", input: v2(family: 0x13, body: ipv4Body)),
        Bad(name: "v2 with an unknown family", input: v2(family: 0x41, body: ipv4Body)),
        Bad(name: "v2 IPv4 too short", input: v2(body: Array(ipv4Body.dropLast()))),
        Bad(name: "v2 IPv6 too short", input: v2(family: 0x21, body: Array(ipv6Body.dropLast()))),
        Bad(name: "v2 longer than the limit", input: v2(body: [UInt8](repeating: 0, count: 1025))),
        Bad(name: "v2 with a length that does not fit in the field", input: v2(body: [], length: 0xFFFF)),
    ]

    @Test("What is not a header is refused, as soon as that is known", arguments: bad)
    func refuses(_ c: Bad) {
        #expect(ProxyHeader.parse(c.input) == .invalid, "\(ProxyHeader.parse(c.input))")
    }

    @Test("The limits are exact: a v1 line of 107 bytes is read, 108 is not; a v2 body of 1024 is read, 1025 is not")
    func limits() {
        // 107 bytes including the CRLF: "PROXY UNKNOWN " is 14, so 91 more characters make 105, plus CRLF = 107.
        let longest = Self.bytes("PROXY UNKNOWN " + String(repeating: "a", count: 91) + "\r\n")
        #expect(longest.count == 107)
        #expect(ProxyHeader.parse(longest) == .header(client: nil, consumed: 107))
        let over = Self.bytes("PROXY UNKNOWN " + String(repeating: "a", count: 92) + "\r\n")
        #expect(ProxyHeader.parse(over) == .invalid)
        #expect(ProxyHeader.parse(Self.v2(family: 0x00, body: [UInt8](repeating: 0, count: 1024))) == .header(client: nil, consumed: 1040))
        #expect(ProxyHeader.parse(Self.v2(family: 0x00, body: [UInt8](repeating: 0, count: 1025))) == .invalid)
    }

    @Test("Whether bytes could still become a PROXY header is what tells a direct client from a spoofed one")
    func couldBeAHeader() {
        #expect(ProxyHeader.couldBeginAHeader(Self.bytes("P")))
        #expect(ProxyHeader.couldBeginAHeader(Self.bytes("PROX")))
        #expect(ProxyHeader.couldBeginAHeader(Self.bytes("PROXY ")))
        #expect(ProxyHeader.couldBeginAHeader([0x0D, 0x0A, 0x0D]))
        #expect(ProxyHeader.couldBeginAHeader([]))
        #expect(!ProxyHeader.couldBeginAHeader(Self.bytes("PRI * HTTP/2.0")))      // the HTTP/2 preface diverges at its third byte
        #expect(!ProxyHeader.couldBeginAHeader(Self.bytes("GET /")))
        #expect(!ProxyHeader.couldBeginAHeader([0x16, 0x03]))
        #expect(!ProxyHeader.couldBeginAHeader([0x0D, 0x0B]))
    }
}
