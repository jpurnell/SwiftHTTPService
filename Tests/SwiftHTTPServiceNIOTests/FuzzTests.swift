import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SwiftHTTPService
import Testing
@testable import SwiftHTTPServiceNIO

/// Seeded, deterministic fuzzing of the transport's parsers: the PROXY protocol header (versions 1 and 2) and the
/// HTTP/1.1 head through a real socket. Every generator is a SplitMix64 with a fixed seed; the seeds and case counts are
/// printed as `RIG-MEASURE` lines. `.timeLimit` is the hang bound for the pure parsers; the socket cases carry their own.
@Suite("Fuzzing the transport parsers", .serialized)
struct TransportFuzzTests {

    static let proxySeed: UInt64 = 0x5EED_0002
    static let headSeed: UInt64 = 0x5EED_0006

    // MARK: Reference pieces for the PROXY protocol

    /// RFC 5952 section 4, written here from the RFC: lower case, no leading zeros, the longest run of two or more zero
    /// groups (the first if tied) as `::`.
    private static func rfc5952(_ groups: [UInt16]) -> String {
        func hex(_ group: UInt16) -> String { String(group, radix: 16) }
        var bestStart = -1, bestLength = 0, start = -1
        for index in 0...8 {
            if index < 8, groups[index] == 0 {
                if start < 0 { start = index }
            } else if start >= 0 {
                if index - start > bestLength { bestStart = start; bestLength = index - start }
                start = -1
            }
        }
        guard bestLength >= 2 else { return groups.map(hex).joined(separator: ":") }
        return groups[..<bestStart].map(hex).joined(separator: ":") + "::" + groups[(bestStart + bestLength)...].map(hex).joined(separator: ":")
    }

    private static func isMapped(_ groups: [UInt16]) -> Bool { groups[0..<5].allSatisfy { $0 == 0 } && groups[5] == 0xFFFF }

    private static func randomGroups(_ rng: inout SplitMix64) -> [UInt16] {
        var groups = (0..<8).map { _ in rng.chance(40) ? UInt16(0) : UInt16.random(in: 0...UInt16.max, using: &rng) }
        if isMapped(groups) { groups[5] = 0x1234 }          // an IPv4-mapped address is reported as the IPv4 address; keep these out of the IPv6 cases
        return groups
    }

    private static func octets(of groups: [UInt16]) -> [UInt8] { groups.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }

    private struct Generated {
        var bytes: [UInt8]
        var client: String?
        var consumed: Int
    }

    private static func port(_ rng: inout SplitMix64) -> Int {
        rng.chance(10) ? rng.pick([0, 1, 65_535, 9, 10, 99, 100]) : rng.int(1...65_535)
    }

    /// A valid version 1 header, with what it must mean worked out from the specification's grammar.
    private static func version1(_ rng: inout SplitMix64) -> Generated {
        let line: String
        var client: String?
        switch rng.int(0...5) {
        case 0:
            line = "PROXY UNKNOWN" + (rng.chance(50) ? " " + String((0..<rng.int(0...40)).map { _ in rng.pick(Array("abc xyz:.0123456789")) }) : "")
        case 1, 2, 3:
            let a = (0..<4).map { _ in rng.chance(10) ? rng.pick([0, 255, 1, 10]) : rng.int(0...255) }
            let b = (0..<4).map { _ in rng.int(0...255) }
            client = a.map(String.init).joined(separator: ".")
            line = "PROXY TCP4 \(client ?? "") \(b.map(String.init).joined(separator: ".")) \(port(&rng)) \(port(&rng))"
        default:
            let a = randomGroups(&rng)
            let b = randomGroups(&rng)
            client = rfc5952(a)
            // The sender may spell an address any legal way; the full upper-case spelling and the compressed one must agree.
            let spelling = rng.chance(50) ? a.map { paddedHex(UInt64($0), width: 4) }.joined(separator: ":") : rfc5952(a)
            line = "PROXY TCP6 \(spelling) \(rfc5952(b)) \(port(&rng)) \(port(&rng))"
        }
        let bytes = Array((line + "\r\n").utf8)
        return Generated(bytes: bytes, client: client, consumed: bytes.count)
    }

    /// A valid version 2 header (binary), per the specification's layout: signature, version and command, family and
    /// transport, a 16-bit length, then the address block and optional TLVs.
    private static func version2(_ rng: inout SplitMix64) -> Generated {
        let signature: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A]
        var command: UInt8 = 0x21
        var family: UInt8
        var body: [UInt8]
        var client: String?
        switch rng.int(0...5) {
        case 0:
            command = 0x20                                                       // LOCAL
            family = rng.pick([0x00, 0x11, 0x21])
            body = (0..<rng.int(0...40)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        case 1, 2:
            family = 0x11
            let src = (0..<4).map { _ in UInt8.random(in: 0...255, using: &rng) }
            body = src + (0..<4).map { _ in UInt8.random(in: 0...255, using: &rng) } + (0..<4).map { _ in UInt8.random(in: 0...255, using: &rng) }
            client = src.map(String.init).joined(separator: ".")
        case 3:
            family = 0x21
            let src = randomGroups(&rng)
            body = octets(of: src) + octets(of: randomGroups(&rng)) + (0..<4).map { _ in UInt8.random(in: 0...255, using: &rng) }
            client = rfc5952(src)
        case 4:
            family = rng.pick([0x00, 0x12, 0x22, 0x31, 0x32, 0x01])             // UNSPEC, UDP, UNIX, or TCP over a family this server does not read
            if family == 0x01 { family = 0x00 }
            body = (0..<rng.int(0...60)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        default:
            family = 0x11
            let src = (0..<4).map { _ in UInt8.random(in: 0...255, using: &rng) }
            // A PP2 TLV is a type, a 16-bit length and a value; this server skips them.
            let tlv: [UInt8] = [0x04, 0x00, 0x03, 1, 2, 3]
            body = src + (0..<8).map { _ in UInt8.random(in: 0...255, using: &rng) } + tlv
            client = src.map(String.init).joined(separator: ".")
        }
        if command == 0x20 { client = nil }
        let bytes = signature + [command, family, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
        return Generated(bytes: bytes, client: client, consumed: bytes.count)
    }

    static let validPerVersion = 15_000

    @Test("Every valid generated v1 and v2 header is read as the specification says: the client it names and the bytes it uses, with any bytes after it left alone (30,000 seeded headers)", .timeLimit(.minutes(2)))
    func proxyValid() {
        var rng = SplitMix64(seed: Self.proxySeed)
        for index in 0..<Self.validPerVersion {
            for (version, generated) in [("v1", Self.version1(&rng)), ("v2", Self.version2(&rng))] {
                let trailer = (0..<rng.int(0...30)).map { _ in UInt8.random(in: 0...255, using: &rng) }
                let outcome = ProxyHeader.parse(generated.bytes + trailer)
                #expect(outcome == .header(client: generated.client, consumed: generated.consumed),
                        "\(version) case \(index) seed \(Self.proxySeed): \(generated.bytes) gave \(outcome)")
            }
        }
        recordMeasurement("PROXY valid fuzz", "\(Self.validPerVersion * 2) headers (v1 and v2), seed \(Self.proxySeed)")
    }

    @Test("Every strict prefix of a valid header is needMore, never a refusal and never a header: a header arriving a byte at a time is read the same (3,000 seeded headers, every prefix)", .timeLimit(.minutes(2)))
    func proxyPrefixes() {
        var rng = SplitMix64(seed: Self.proxySeed &+ 1)
        var prefixes = 0
        for index in 0..<1_500 {
            for (version, generated) in [("v1", Self.version1(&rng)), ("v2", Self.version2(&rng))] {
                for length in 0..<generated.bytes.count {
                    let outcome = ProxyHeader.parse(Array(generated.bytes[0..<length]))
                    prefixes += 1
                    #expect(outcome == .needMore, "\(version) case \(index) seed \(Self.proxySeed &+ 1): \(length) of \(generated.bytes.count) bytes gave \(outcome)")
                }
            }
        }
        recordMeasurement("PROXY prefix fuzz", "3000 headers, \(prefixes) prefixes, seed \(Self.proxySeed &+ 1)")
    }

    /// A header with something done to it: a bit flipped, a byte removed, inserted or repeated, or a tail cut off.
    private static func mutate(_ original: [UInt8], _ rng: inout SplitMix64) -> [UInt8] {
        var bytes = original
        for _ in 0..<rng.int(1...3) {
            guard !bytes.isEmpty else { break }
            let index = rng.int(0...bytes.count - 1)
            switch rng.int(0...4) {
            case 0: bytes[index] ^= UInt8(1) << UInt8(rng.int(0...7))
            case 1: bytes.remove(at: index)
            case 2: bytes.insert(UInt8.random(in: 0...255, using: &rng), at: index)
            case 3: bytes.insert(bytes[index], at: index)
            default: bytes.removeSubrange(index...)
            }
        }
        return bytes
    }

    /// The independent reference for a version 1 TCP4 line: `PROXY TCP4 <ip> <ip> <port> <port>\r\n`, whole, with decimal
    /// octets of no leading zero, ports with no leading zero, 107 bytes at most, and nothing else in it.
    private static func referenceV1TCP4(_ bytes: [UInt8]) -> String?? {
        guard bytes.starts(with: Array("PROXY TCP4 ".utf8)), bytes.suffix(2).elementsEqual([0x0D, 0x0A]) else { return .none }
        guard bytes.count <= 107 else { return .some(nil) }
        let line = Array(bytes.dropLast(2))
        guard line.allSatisfy({ (0x20...0x7E).contains($0) }) else { return .some(nil) }
        let fields = String(decoding: line, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6 else { return .some(nil) }
        func ip(_ text: String) -> Bool {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 4 && parts.allSatisfy { part in
                part.count >= 1 && part.count <= 3 && part.allSatisfy { "0123456789".contains($0) } && (part.count == 1 || part.first != "0") && Int(part).map { $0 <= 255 } == true
            }
        }
        func port(_ text: String) -> Bool {
            text.count >= 1 && text.count <= 5 && text.allSatisfy { "0123456789".contains($0) } && (text.count == 1 || text.first != "0") && Int(text).map { $0 <= 65_535 } == true
        }
        guard ip(fields[2]), ip(fields[3]), port(fields[4]), port(fields[5]) else { return .some(nil) }
        return .some(fields[2])
    }

    static let mutatedPerVersion = 15_000

    @Test("Mutated headers: the parser never traps, never claims more bytes than the bound, agrees with a reference on v1 TCP4 lines, and a header or a refusal does not change when more bytes arrive (30,000 seeded mutations)", .timeLimit(.minutes(2)))
    func proxyMutated() {
        var rng = SplitMix64(seed: Self.proxySeed &+ 2)
        var accepted = 0, refused = 0, waiting = 0, referenceChecked = 0
        for index in 0..<Self.mutatedPerVersion {
            for (version, generated) in [("v1", Self.version1(&rng)), ("v2", Self.version2(&rng))] {
                let input = Self.mutate(generated.bytes, &rng)
                let outcome = ProxyHeader.parse(input)
                let context = "\(version) case \(index) seed \(Self.proxySeed &+ 2): \(input)"
                switch outcome {
                case .header(_, let consumed):
                    accepted += 1
                    #expect(consumed <= input.count, "claims \(consumed) of \(input.count) bytes: \(context)")
                    #expect(consumed <= (version == "v1" ? ProxyHeader.maximumLineLength : 16 + ProxyHeader.maximumBodyLength), "over the bound: \(context)")
                case .invalid: refused += 1
                case .needMore: waiting += 1
                }
                // More bytes arriving cannot change a header or a refusal; only "need more" may become something else.
                if outcome != .needMore {
                    let more = input + (0..<rng.int(1...6)).map { _ in UInt8.random(in: 0...255, using: &rng) }
                    #expect(ProxyHeader.parse(more) == outcome, "unstable under extension: \(context)")
                }
                if version == "v1", let expected = Self.referenceV1TCP4(input) {
                    // Only whole lines (one CRLF, at the end) are compared; the reference answers .some(client) or .some(nil).
                    if input.dropLast(2).contains(0x0D) || input.dropLast(2).contains(0x0A) { continue }
                    referenceChecked += 1
                    switch outcome {
                    case .header(let client, let consumed):
                        #expect(expected == client && consumed == input.count, "accepted, reference says \(String(describing: expected)): \(context)")
                    case .invalid, .needMore:
                        #expect(expected == nil, "refused, reference accepts \(String(describing: expected)): \(context)")
                    }
                }
            }
        }
        #expect(accepted > 3_000 && refused > 3_000, "the mutations should reach both outcomes (\(accepted) accepted, \(refused) refused)")
        recordMeasurement("PROXY mutation fuzz", "\(Self.mutatedPerVersion * 2) cases, seed \(Self.proxySeed &+ 2); \(accepted) headers, \(refused) refusals, \(waiting) need-more; \(referenceChecked) v1 TCP4 lines checked against the reference")
    }

    @Test("Arbitrary bytes, and a header with a length field that lies, never trap and never claim bytes that are not there (20,000 seeded inputs)", .timeLimit(.minutes(2)))
    func proxyArbitrary() {
        var rng = SplitMix64(seed: Self.proxySeed &+ 3)
        let signature = Array(ProxyHeader.v2Signature)
        for index in 0..<20_000 {
            var input: [UInt8]
            switch rng.int(0...3) {
            case 0: input = (0..<rng.int(0...200)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            case 1: input = Array("PROXY ".utf8) + (0..<rng.int(0...120)).map { _ in UInt8.random(in: 0x20...0x7E, using: &rng) }
            case 2: input = signature + (0..<rng.int(0...80)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            default:
                // A version 2 header whose length field says anything from nothing to 65,535, with few bytes behind it.
                let length = rng.chance(50) ? rng.int(0...65_535) : rng.int(1_020...1_030)
                input = signature + [rng.pick([0x20, 0x21]), rng.pick([0x00, 0x11, 0x21, 0x31]), UInt8(length >> 8), UInt8(length & 0xFF)]
                    + (0..<rng.int(0...50)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            }
            if case .header(_, let consumed) = ProxyHeader.parse(input) {
                #expect(consumed <= input.count, "case \(index) seed \(Self.proxySeed &+ 3): claims \(consumed) of \(input.count)")
            }
        }
        recordMeasurement("PROXY arbitrary-bytes fuzz", "20000 cases, seed \(Self.proxySeed &+ 3)")
    }
}
