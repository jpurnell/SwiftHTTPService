import Foundation
import Testing
@testable import SwiftHTTPService

/// CIDR blocks of addresses, for naming the proxies a server trusts. Expected values are worked out by hand from
/// the prefix lengths: a /24 holds the 256 addresses that share its first 24 bits, and so on.
@Suite("Network blocks")
struct NetworkBlockTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let block: String
        let address: String
        let expected: Bool
        var testDescription: String { "\(address) in \(block)" }
    }

    static let membership: [Case] = [
        // IPv4, at the edges of a /24
        Case(block: "10.1.2.0/24", address: "10.1.2.0", expected: true),
        Case(block: "10.1.2.0/24", address: "10.1.2.255", expected: true),
        Case(block: "10.1.2.0/24", address: "10.1.3.0", expected: false),
        Case(block: "10.1.2.0/24", address: "10.1.1.255", expected: false),
        // a prefix that is not a whole number of octets: /25 of 10.1.2.0 is .0 to .127
        Case(block: "10.1.2.0/25", address: "10.1.2.127", expected: true),
        Case(block: "10.1.2.0/25", address: "10.1.2.128", expected: false),
        // a /8, a /31 and a /32
        Case(block: "10.0.0.0/8", address: "10.255.255.255", expected: true),
        Case(block: "10.0.0.0/8", address: "11.0.0.0", expected: false),
        Case(block: "192.0.2.4/31", address: "192.0.2.5", expected: true),
        Case(block: "192.0.2.4/31", address: "192.0.2.6", expected: false),
        Case(block: "192.0.2.7/32", address: "192.0.2.7", expected: true),
        Case(block: "192.0.2.7/32", address: "192.0.2.8", expected: false),
        // a bare address is a single host
        Case(block: "198.51.100.9", address: "198.51.100.9", expected: true),
        Case(block: "198.51.100.9", address: "198.51.100.10", expected: false),
        // host bits in the block are ignored: 10.1.2.3/24 is 10.1.2.0/24
        Case(block: "10.1.2.3/24", address: "10.1.2.200", expected: true),
        // IPv6
        Case(block: "::1", address: "::1", expected: true),
        Case(block: "::1", address: "::2", expected: false),
        Case(block: "fd00::/8", address: "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", expected: true),
        Case(block: "fd00::/8", address: "fe00::", expected: false),
        Case(block: "2001:db8::/32", address: "2001:db8:ffff::1", expected: true),
        Case(block: "2001:db8::/32", address: "2001:db9::1", expected: false),
        Case(block: "2001:db8::/33", address: "2001:db8:7fff::1", expected: true),
        Case(block: "2001:db8::/33", address: "2001:db8:8000::", expected: false),
        // the two families never match each other, except that an IPv4 address written as IPv4-mapped IPv6 is that IPv4 address
        Case(block: "10.0.0.0/8", address: "fd00::1", expected: false),
        Case(block: "fd00::/8", address: "10.0.0.1", expected: false),
        Case(block: "10.0.0.0/8", address: "::ffff:10.1.2.3", expected: true),
        Case(block: "10.0.0.0/8", address: "::ffff:11.1.2.3", expected: false),
        // what is not an address is in no block
        Case(block: "10.0.0.0/8", address: "10.0.0.256", expected: false),
        Case(block: "10.0.0.0/8", address: "not an address", expected: false),
        Case(block: "10.0.0.0/8", address: "", expected: false),
        Case(block: "10.0.0.0/8", address: "10.0.0.1:80", expected: false),
        Case(block: "10.0.0.0/8", address: "10.0.0.1/8", expected: false),
    ]

    @Test("A block holds exactly the addresses that share its prefix", arguments: membership)
    func contains(_ c: Case) throws {
        #expect(try NetworkBlock(c.block).contains(c.address) == c.expected)
    }

    static let refused: [String] = [
        "", " ", "10.0.0.0/", "/8", "10.0.0.0/33", "10.0.0.0/-1", "10.0.0.0/abc", "10.0.0.0/8/8", "10.0.0/8", "10.0.0.256/8",
        "::1/129", "::1/-1", "gggg::/8", "10.0.0.0/08x", "10.0.0.0 /8", "10.0.0.0/ 8", "host.example/8",
        "10.0.0.0/+8", "10.0.0.0/\u{0661}",              // a sign, or a digit that is not ASCII, is not a prefix length
        "10.0.0.1\u{0}garbage", "10.0.0.1\u{0}/8",       // a NUL ends a C string: nothing after it may be hidden there
        "::ffff:10.0.0.0/104", "::ffff:10.1.2.3",         // IPv4-mapped as a block: write the IPv4 form
        "0.0.0.0/0", "::/0",           // every address: trusting this is trusting nobody in particular
    ]

    @Test("What is not a block, and the block of every address, is refused naming the field and not the text", arguments: refused)
    func refuses(_ text: String) {
        #expect(throws: ConfigurationError(field: "trustedProxies", reason: .malformed)) { _ = try NetworkBlock(text) }
    }

    @Test("The edges of the prefix are accepted: /1, /32, /128")
    func prefixEdges() throws {
        #expect(try NetworkBlock("128.0.0.0/1").contains("200.0.0.1"))
        #expect(try NetworkBlock("128.0.0.0/1").contains("100.0.0.1") == false)
        #expect(try NetworkBlock("1.2.3.4/32").contains("1.2.3.4"))
        #expect(try NetworkBlock("::1/128").contains("::1"))
        #expect(try NetworkBlock("8000::/1").contains("ffff::"))
    }

    @Test("A block prints as it was written, with the prefix made explicit")
    func description() throws {
        #expect(try NetworkBlock("10.1.2.0/24").description == "10.1.2.0/24")
        #expect(try NetworkBlock("198.51.100.9").description == "198.51.100.9/32")
        #expect(try NetworkBlock("::1").description == "::1/128")
    }

    // The IPv4 and IPv6 grammars, by hand from RFC 4291 section 2.2 and RFC 5952: the places a parser goes wrong.
    static let addressForms: [(String, Bool)] = [
        ("0.0.0.0", true), ("255.255.255.255", true), ("1.2.3.4", true), ("10.0.0.0", true),
        ("256.0.0.0", false), ("1.2.3", false), ("1.2.3.4.5", false), ("1..3.4", false), (".1.2.3", false), ("1.2.3.", false),
        ("01.2.3.4", false), ("1.2.3.04", false), ("001.2.3.4", false), ("+1.2.3.4", false), ("-1.2.3.4", false), ("1.2.3.4a", false),
        ("0x1.2.3.4", false), ("1.2.3.1000", false), (" 1.2.3.4", false), ("1.2.3.4 ", false), ("1.2.3.\u{0661}", false),
        ("::", true), ("::1", true), ("1::", true), ("1::1", true), ("1:2:3:4:5:6:7:8", true), ("1:2:3:4:5:6:7::", true),
        ("::2:3:4:5:6:7:8", true), ("1:2:3:4:5:6::8", true), ("2001:DB8::ABCD", true), ("2001:db8::abcd", true),
        ("1:2:3:4:5:6:7", false), ("1:2:3:4:5:6:7:8:9", false), ("1:2:3:4:5:6:7:8::", false), ("::1:2:3:4:5:6:7:8", false),
        ("1::2::3", false), (":::", false), ("1:::2", false), (":1:2:3:4:5:6:7", false), ("1:2:3:4:5:6:7:", false), (":1::2", false),
        ("12345::", false), ("g::", false), ("1:2:3:4:5:6:7:fffff", false), ("::-1", false), ("::+1", false), ("::0x1", false),
        ("fe80::1%eth0", false), ("[::1]", false), ("::1/128", false), ("::1.2.3.4", true), ("::ffff:1.2.3.4", true),
        ("1:2:3:4:5:6:1.2.3.4", true), ("1:2:3:4:5:6:7:1.2.3.4", false), ("1.2.3.4::", false), ("::1.2.3.4:5", false),
        ("::ffff:1.2.3.256", false), ("::ffff:01.2.3.4", false),
        ("1:2:3::4:5:6::7:8", false),                      // three pieces around two ::, eight groups in all
        ("00001::", false), ("::00001", false), ("1:00001::2", false),   // five digits, though the value is small
        ("G::", false), ("::1G", false), ("::@", false), ("::`", false), ("::/", false), ("::0:", false), ("::+1", false),
        ("::-0", false), ("::0x", false), ("0000::", true), ("::fFfF", true), ("::FFFF", true),
    ]

    @Test("The address grammars accept what RFC 4291 allows and refuse what a parser could read two ways", arguments: addressForms)
    func addressGrammar(_ pair: (String, Bool)) {
        #expect(NetworkBlock.isAddress(pair.0) == pair.1, "\(pair.0.debugDescription)")
    }

    @Test("IPv6 is written in the RFC 5952 form: lower case, no leading zeros, the longest run of zero groups as ::")
    func ipv6Text() throws {
        let cases: [(String, String)] = [
            ("2001:0DB8:0000:0000:0000:0000:0000:0000/32", "2001:db8::/32"),
            ("2001:db8:0:0:1:0:0:1/128", "2001:db8::1:0:0:1/128"),       // two runs of two: the first is compressed
            ("2001:db8:0:1:0:0:0:1/128", "2001:db8:0:1::1/128"),         // the longer run wins
            ("1:0:2:3:4:5:6:7/128", "1:0:2:3:4:5:6:7/128"),              // a single zero group is not compressed
            ("0:0:0:0:0:0:0:1/128", "::1/128"),
            ("0:0:0:0:0:0:0:0/8", "::/8"),
            ("1:2:3:4:5:6:7:0/128", "1:2:3:4:5:6:7:0/128"),
            ("1::/16", "1::/16"),
            ("fd00::/8", "fd00::/8"),
            ("fdAB:1::/16", "fdab::/16"),                                // the host bits are masked: /16 keeps fdab
        ]
        for (input, expected) in cases { #expect(try NetworkBlock(input).description == expected, "\(input)") }
    }

    @Test("An address that only looks IPv4-mapped is its own IPv6 address, not an IPv4 one")
    func lookalikeMapped() throws {
        // ::ff:1.2.3.4 has 0x00 0xff in bytes 10 and 11, not 0xff 0xff; it is not the IPv4 address 1.2.3.4.
        #expect(try NetworkBlock("1.2.3.4").contains("::ff:1.2.3.4") == false)
        #expect(try NetworkBlock("1.2.3.4").contains("::ffff:1.2.3.4"))
        #expect(try NetworkBlock("1.2.3.4").contains("0:0:0:0:0:ffff:102:304"))
        #expect(try NetworkBlock("1.2.3.4").contains("1:0:0:0:0:ffff:1.2.3.4") == false)
        // Every one of the first ten octets must be zero: a one in octet 9 (here, group 5) makes it another address.
        #expect(try NetworkBlock("1.2.3.4").contains("::1:ffff:1.2.3.4") == false)
        #expect(try NetworkBlock("1.2.3.4").contains("0:0:0:0:100:ffff:1.2.3.4") == false)
    }

    @Test("An address has one canonical text: IPv4 dotted, IPv6 in the RFC 5952 form, IPv4-mapped IPv6 as its IPv4 self")
    func canonical() {
        #expect(NetworkBlock.canonicalAddress("203.0.113.9") == "203.0.113.9")
        #expect(NetworkBlock.canonicalAddress("2001:0DB8:0:0:0:0:0:9") == "2001:db8::9")
        #expect(NetworkBlock.canonicalAddress("::ffff:203.0.113.9") == "203.0.113.9")
        #expect(NetworkBlock.canonicalAddress("::FFFF:cb00:7109") == "203.0.113.9")
        #expect(NetworkBlock.canonicalAddress("::1") == "::1")
        #expect(NetworkBlock.canonicalAddress("not an address") == nil)
        #expect(NetworkBlock.canonicalAddress("10.0.0.0/8") == nil)
        #expect(NetworkBlock.canonicalAddress("") == nil)
    }

    @Test("Octets become that same text: 4 for IPv4, 16 for IPv6, and nothing for any other length")
    func canonicalFromOctets() {
        #expect(NetworkBlock.canonicalAddress(octets: [203, 0, 113, 9]) == "203.0.113.9")
        #expect(NetworkBlock.canonicalAddress(octets: [0x20, 0x01, 0x0D, 0xB8] + [UInt8](repeating: 0, count: 11) + [9]) == "2001:db8::9")
        #expect(NetworkBlock.canonicalAddress(octets: [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 203, 0, 113, 9]) == "203.0.113.9")
        #expect(NetworkBlock.canonicalAddress(octets: [1, 2, 3]) == nil)
        #expect(NetworkBlock.canonicalAddress(octets: []) == nil)
        #expect(NetworkBlock.canonicalAddress(octets: [UInt8](repeating: 0, count: 15)) == nil)
    }

    @Test("A text is an address on its own, with no prefix, if it is an IPv4 or IPv6 literal")
    func isAddress() {
        #expect(NetworkBlock.isAddress("203.0.113.9"))
        #expect(NetworkBlock.isAddress("2001:db8::1"))
        #expect(NetworkBlock.isAddress("::ffff:203.0.113.9"))
        #expect(!NetworkBlock.isAddress("203.0.113.9/32"))
        #expect(!NetworkBlock.isAddress("203.0.113.9:80"))
        #expect(!NetworkBlock.isAddress("[::1]"))
        #expect(!NetworkBlock.isAddress("unknown"))
        #expect(!NetworkBlock.isAddress(""))
        #expect(!NetworkBlock.isAddress("1.2.3"))
        #expect(!NetworkBlock.isAddress("1.2.3.4\u{0}x"))
    }
}
