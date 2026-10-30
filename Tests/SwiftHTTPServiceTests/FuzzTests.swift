import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// Seeded, deterministic fuzzing of the core's parsers. Each target is driven by a SplitMix64 generator with a fixed
/// seed, and is checked two ways: it never traps (the test process is still alive), and it agrees with a small reference
/// written here from the grammar the documentation states, not from the code under test. `.timeLimit` is the hang bound.
///
/// Seeds and case counts are in the constants below and are printed as `RIG-MEASURE` lines.
@Suite("Fuzzing the core parsers", .serialized)
struct CoreFuzzTests {

    static let targetSeed: UInt64 = 0x5EED_0001
    static let formSeed: UInt64 = 0x5EED_0003
    static let cookieSeed: UInt64 = 0x5EED_0004
    static let cidrSeed: UInt64 = 0x5EED_0005

    // MARK: Shared reference pieces

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    private static func hexPair(_ high: UInt8, _ low: UInt8) -> UInt8? {
        guard isHex(high), isHex(low), let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16) else { return nil }
        return value
    }

    /// Percent-decoding as RFC 3986 section 2.1 defines it, with `plusIsSpace` for form bodies. The result is nil when a
    /// `%` is not followed by two hex digits, and the decoded bytes are returned otherwise.
    private static func percentDecode(_ bytes: [UInt8], plusIsSpace: Bool) -> [UInt8]? {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25 {
                guard i + 2 < bytes.count, let value = hexPair(bytes[i + 1], bytes[i + 2]) else { return nil }
                out.append(value)
                i += 3
            } else {
                out.append(plusIsSpace && bytes[i] == 0x2B ? 0x20 : bytes[i])
                i += 1
            }
        }
        return out
    }

    private static func validUTF8String(_ bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
        return Array(text.utf8) == bytes ? text : nil
    }

    // MARK: (a) The request target

    private struct ReferenceTarget: Equatable {
        var segments: [String]
        var query: [[String?]]
    }

    /// RFC 9112 origin-form, as this kit restricts it: a leading `/`; printable ASCII; no fragment; `.` and `..` segments
    /// and empty interior segments refused; percent-escapes well formed and decoding to UTF-8 without NUL.
    private static func referenceTarget(_ target: String) -> ReferenceTarget? {
        let bytes = Array(target.utf8)
        guard bytes.first == 0x2F else { return nil }
        for byte in bytes where !(0x21...0x7E).contains(byte) || byte == 0x23 { return nil }
        var path = bytes
        var query: [UInt8] = []
        if let question = bytes.firstIndex(of: 0x3F) {
            path = Array(bytes[..<question])
            query = Array(bytes[(question + 1)...])
        }
        func decode(_ part: [UInt8]) -> String? {
            guard let raw = percentDecode(part, plusIsSpace: false), !raw.contains(0) else { return nil }
            return validUTF8String(raw)
        }
        var segments: [String] = []
        let rest = Array(path.dropFirst())
        if !rest.isEmpty {
            let pieces = rest.split(separator: 0x2F, omittingEmptySubsequences: false).map(Array.init)
            for (index, piece) in pieces.enumerated() {
                if piece.isEmpty {
                    guard index == pieces.count - 1 else { return nil }
                    segments.append("")
                    continue
                }
                guard let text = decode(piece), text != ".", text != ".." else { return nil }
                segments.append(text)
            }
        }
        var items: [[String?]] = []
        for pair in query.split(separator: 0x26, omittingEmptySubsequences: true).map(Array.init) {
            if let equals = pair.firstIndex(of: 0x3D) {
                guard let name = decode(Array(pair[..<equals])), let value = decode(Array(pair[(equals + 1)...])) else { return nil }
                items.append([name, value])
            } else {
                guard let name = decode(pair) else { return nil }
                items.append([name, nil])
            }
        }
        return ReferenceTarget(segments: segments, query: items)
    }

    static let targetCases = 30_000

    @Test("The request-target parser agrees with a reference of the origin-form grammar on 30,000 seeded targets, and never traps", .timeLimit(.minutes(2)))
    func requestTarget() throws {
        var rng = SplitMix64(seed: Self.targetSeed)
        let pieces = ["/", "/", "a", "b", "z9", "0", "A", "f", "%", "%41", "%2F", "%2f", "%C3%A9", "%00", "%zz", "%4", "%E2%82%AC", "%FF", "%c3",
                      "?", "&", "=", ".", "..", "#", " ", "é", "~", "+", "\u{0}", "\r", "%2e", "%2E%2E", "a=b", "x=", "%3D", "-", "_"]
        var accepted = 0
        for index in 0..<Self.targetCases {
            var target = rng.chance(88) ? "/" : ""
            for _ in 0..<rng.int(0...14) { target += rng.pick(pieces) }
            let expected = Self.referenceTarget(target)
            do {
                let request = try Request(method: .get, target: target, headers: HTTPFields(), body: Data())
                accepted += 1
                let reference = try #require(expected, "case \(index) seed \(Self.targetSeed): accepted \(target.debugDescription), the grammar refuses it")
                #expect(request.pathSegments == reference.segments, "case \(index): \(target.debugDescription)")
                #expect(request.query.map { [$0.name, $0.value] } == reference.query, "case \(index): \(target.debugDescription)")
            } catch let error as RequestError {
                #expect(error == .malformedTarget)
                #expect(expected == nil, "case \(index) seed \(Self.targetSeed): refused \(target.debugDescription), the grammar accepts it as \(String(describing: expected))")
            }
        }
        recordMeasurement("request-target fuzz", "\(Self.targetCases) cases, seed \(Self.targetSeed), \(accepted) accepted")
        #expect(accepted > 1000, "the generator should reach the accepting path often enough to test it (\(accepted))")
    }

    // MARK: (c) The form decoder

    private static func formRequest(_ body: [UInt8]) throws -> Request {
        var headers = HTTPFields()
        headers[.contentType] = "application/x-www-form-urlencoded"
        return try Request(method: .post, target: "/f", headers: headers, body: Data(body))
    }

    /// The faults a body has under the stated rules, and the fields it decodes to when there are none.
    private static func referenceForm(_ body: [UInt8], maxFields: Int, maxLength: Int) -> (faults: [FormError], fields: [[String]]) {
        var faults = [FormError]()
        if body.contains(where: { !(0x21...0x7E).contains($0) }) { faults.append(.malformed) }
        if body.isEmpty { return ([], []) }
        let segments = body.split(separator: 0x26, omittingEmptySubsequences: false).map(Array.init)
        if segments.contains(where: \.isEmpty) { faults.append(.malformed) }
        if segments.count > maxFields { faults.append(.tooManyFields) }
        var fields: [[String]] = []
        for segment in segments where !segment.isEmpty {
            let parts = segment.split(separator: 0x3D, maxSplits: 1, omittingEmptySubsequences: false).map(Array.init)
            let rawName = parts[0]
            let rawValue = parts.count > 1 ? parts[1] : []
            var texts: [String] = []
            for raw in [rawName, rawValue] {
                guard let decoded = percentDecode(raw, plusIsSpace: true) else { faults.append(.malformed); texts.append(""); continue }
                if decoded.contains(0) { faults.append(.malformed) }
                if decoded.count > maxLength { faults.append(.fieldTooLong) }
                guard let text = validUTF8String(decoded) else { faults.append(.encoding); texts.append(""); continue }
                texts.append(text)
            }
            if rawName.isEmpty { faults.append(.malformed) }
            fields.append(texts)
        }
        return (faults, fields)
    }

    static let formCases = 30_000

    @Test("The form decoder agrees with a reference of the urlencoded rules on 30,000 seeded bodies: it accepts exactly what has no fault, and any error it gives is one of the body's faults", .timeLimit(.minutes(2)))
    func formAgreement() throws {
        var rng = SplitMix64(seed: Self.formSeed)
        let pieces = ["a", "b", "name", "1", "=", "=", "&", "&", "+", "%", "%41", "%2B", "%26", "%3D", "%C3%A9", "%E2%82%AC", "%FF", "%C3", "%00", "%4", "%zz",
                      " ", "é", "\u{0}", "\n", "~", "x=1", "k=v", "%0A"]
        let maxFields = 5
        let maxLength = 6
        var accepted = 0
        for index in 0..<Self.formCases {
            var text = ""
            for _ in 0..<rng.int(0...12) { text += rng.pick(pieces) }
            let bytes = Array(text.utf8)
            let reference = Self.referenceForm(bytes, maxFields: maxFields, maxLength: maxLength)
            do {
                let form = try Self.formRequest(bytes).form(maximumFields: maxFields, maximumFieldLength: maxLength)
                accepted += 1
                #expect(reference.faults.isEmpty, "case \(index) seed \(Self.formSeed): accepted \(text.debugDescription) which has faults \(reference.faults)")
                #expect(form.fields.map { [$0.name, $0.value] } == reference.fields, "case \(index): \(text.debugDescription)")
            } catch let error as FormError {
                #expect(reference.faults.contains(error), "case \(index) seed \(Self.formSeed): \(text.debugDescription) gave \(error), faults are \(reference.faults)")
            }
        }
        recordMeasurement("form agreement fuzz", "\(Self.formCases) cases, seed \(Self.formSeed), \(accepted) accepted")
        #expect(accepted > 1000, "the generator should reach the accepting path often enough to test it (\(accepted))")
    }

    /// The `application/x-www-form-urlencoded` serializer of the WHATWG URL standard: unreserved bytes (`*-._` and
    /// alphanumerics) as they are, a space as `+`, every other byte as `%XX` in upper case.
    private static func encodeForm(_ text: String, spaceAsPlus: Bool) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2A, 0x2D, 0x2E, 0x5F: out += String(UnicodeScalar(byte))
            case 0x20 where spaceAsPlus: out += "+"
            default: out += "%" + paddedHex(UInt64(byte), width: 2)
            }
        }
        return out
    }

    static let formRoundTripCases = 10_000

    @Test("Any list of fields, encoded by the WHATWG serializer, decodes to itself, in order, duplicates kept (10,000 seeded lists)", .timeLimit(.minutes(2)))
    func formRoundTrip() throws {
        var rng = SplitMix64(seed: Self.formSeed &+ 1)
        let alphabet = ["a", "Z", "0", " ", "&", "=", "%", "+", "é", "€", "😀", "/", "?", "~", "*", "-", ".", "_", "\t", "\n", "#", ";", "'", "\""]
        func text(_ minimum: Int) -> String {
            var out = ""
            for _ in 0..<rng.int(minimum...6) { out += rng.pick(alphabet) }
            return out
        }
        for index in 0..<Self.formRoundTripCases {
            let count = rng.int(0...8)
            var expected: [[String]] = []
            for _ in 0..<count { expected.append([text(1), text(0)]) }
            let body = expected.map { Self.encodeForm($0[0], spaceAsPlus: rng.chance(50)) + "=" + Self.encodeForm($0[1], spaceAsPlus: rng.chance(50)) }.joined(separator: "&")
            let form = try Self.formRequest(Array(body.utf8)).form()
            #expect(form.fields.map { [$0.name, $0.value] } == expected, "case \(index) seed \(Self.formSeed &+ 1): body \(body)")
        }
        recordMeasurement("form round-trip fuzz", "\(Self.formRoundTripCases) cases, seed \(Self.formSeed &+ 1)")
    }

    // MARK: (d) The cookie parser

    private static func isToken(_ text: String) -> Bool {
        let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        return !text.isEmpty && text.utf8.allSatisfy(allowed.contains)
    }

    /// RFC 6265 section 5.4 read leniently, as the README says: pairs split on `;`, a pair with no `=` or a non-token name
    /// skipped, optional whitespace around the value dropped, one pair of surrounding quotes removed.
    private static func referenceCookies(_ lines: [String]) -> [[String]] {
        var out: [[String]] = []
        for line in lines {
            for piece in line.split(separator: ";", omittingEmptySubsequences: true) {
                var chars = Array(piece)
                while let first = chars.first, first == " " || first == "\t" { chars.removeFirst() }
                guard let equals = chars.firstIndex(of: "=") else { continue }
                let name = String(chars[..<equals])
                guard isToken(name) else { continue }
                var value = Array(chars[(equals + 1)...])
                while let first = value.first, first == " " || first == "\t" { value.removeFirst() }
                while let last = value.last, last == " " || last == "\t" { value.removeLast() }
                if value.count >= 2, value.first == "\"", value.last == "\"" { value = Array(value.dropFirst().dropLast()) }
                out.append([name, String(value)])
            }
        }
        return out
    }

    static let cookieCases = 20_000

    @Test("The cookie reader agrees with a reference of RFC 6265 section 5.4 on 20,000 seeded Cookie fields, and never throws or traps", .timeLimit(.minutes(2)))
    func cookieAgreement() throws {
        var rng = SplitMix64(seed: Self.cookieSeed)
        let pieces = ["a", "b", "sid", "=", "=", ";", ";", " ", "\t", "\"", "x y", "%", "/", "1", "token", "!", "(", ")", ",", "{", "}", "@", "==", "; ", "\"q\"", "é"]
        for index in 0..<Self.cookieCases {
            var lines: [String] = []
            for _ in 0..<rng.int(1...3) {
                var line = ""
                for _ in 0..<rng.int(0...10) { line += rng.pick(pieces) }
                lines.append(line)
            }
            var headers = HTTPFields()
            for line in lines { headers.append(HTTPField(name: .cookie, value: line)) }
            let request = try Request(method: .get, target: "/", headers: headers, body: Data())
            // What the field really holds (the HTTP types library may normalise a value), then what the grammar says.
            let held = headers[values: .cookie]
            #expect(request.cookies.map { [$0.name, $0.value] } == Self.referenceCookies(held), "case \(index) seed \(Self.cookieSeed): \(held.debugDescription)")
        }
        recordMeasurement("cookie agreement fuzz", "\(Self.cookieCases) cases, seed \(Self.cookieSeed)")
    }

    @Test("A cookie the builder accepts is read back by the reader with the same name and value (5,000 seeded cookies)", .timeLimit(.minutes(2)))
    func cookieRoundTrip() throws {
        var rng = SplitMix64(seed: Self.cookieSeed &+ 1)
        let nameChars = Array("abcxyzABCXYZ0189!#$%&'*+-.^_`|~")
        let valueChars = Array("abcXYZ019!#$%&'()*+-./:<=>?@[]^_`{|}~")
        var built = 0
        for index in 0..<5_000 {
            var pairs: [(String, String)] = []
            for _ in 0..<rng.int(1...4) {
                let name = String((0..<rng.int(1...6)).map { _ in rng.pick(nameChars) })
                let value = String((0..<rng.int(0...8)).map { _ in rng.pick(valueChars) })
                guard let cookie = try? Cookie(name: name, value: value, path: nil) else { continue }
                pairs.append((cookie.name, cookie.value))
                built += 1
            }
            var headers = HTTPFields()
            headers[.cookie] = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
            let request = try Request(method: .get, target: "/", headers: headers, body: Data())
            #expect(request.cookies.map { [$0.name, $0.value] } == pairs.map { [$0.0, $0.1] }, "case \(index) seed \(Self.cookieSeed &+ 1)")
        }
        #expect(built > 5_000, "the builder should accept most generated cookies (\(built))")
    }

    // MARK: (e) CIDR parsing

    private static func hex(_ group: UInt16) -> String { String(group, radix: 16) }

    /// RFC 5952 section 4: lower case, no leading zeros, the longest run of two or more zero groups (the first if tied) as `::`.
    private static func rfc5952(_ groups: [UInt16]) -> String {
        var bestStart = -1, bestLength = 0
        var start = -1
        for index in 0...8 {
            if index < 8, groups[index] == 0 {
                if start < 0 { start = index }
            } else if start >= 0 {
                if index - start > bestLength { bestStart = start; bestLength = index - start }
                start = -1
            }
        }
        guard bestLength >= 2 else { return groups.map(hex).joined(separator: ":") }
        let head = groups[..<bestStart].map(hex).joined(separator: ":")
        let tail = groups[(bestStart + bestLength)...].map(hex).joined(separator: ":")
        return head + "::" + tail
    }

    private static func v4Text(_ value: UInt32) -> String {
        "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    static let cidrCases = 10_000

    @Test("IPv4 CIDR blocks contain exactly the addresses sharing their first p bits (10,000 seeded blocks, 8 probes each), including as IPv4-mapped IPv6", .timeLimit(.minutes(2)))
    func cidrV4() throws {
        var rng = SplitMix64(seed: Self.cidrSeed)
        for index in 0..<Self.cidrCases {
            let network = UInt32.random(in: 0...UInt32.max, using: &rng)
            let prefix = rng.int(1...32)
            let block = try NetworkBlock("\(Self.v4Text(network))/\(prefix)")
            let mask: UInt32 = prefix == 32 ? .max : ~(UInt32.max >> UInt32(prefix))
            for probeIndex in 0..<8 {
                var probe = UInt32.random(in: 0...UInt32.max, using: &rng)
                if probeIndex % 2 == 0 {
                    probe = network ^ (UInt32(1) << UInt32(rng.int(0...31)))              // differs from the network in exactly one bit
                } else if probeIndex == 1 {
                    probe = network | ~mask                                               // the last address of the block
                }
                let expected = (probe & mask) == (network & mask)
                #expect(block.contains(Self.v4Text(probe)) == expected, "case \(index) seed \(Self.cidrSeed): \(block) \(Self.v4Text(probe))")
                #expect(block.contains("::ffff:" + Self.v4Text(probe)) == expected, "case \(index): mapped \(Self.v4Text(probe)) in \(block)")
            }
            #expect(block.description == "\(Self.v4Text(network & mask))/\(prefix)", "host bits are cleared in the block's text")
        }
        recordMeasurement("CIDR v4 fuzz", "\(Self.cidrCases) blocks, seed \(Self.cidrSeed)")
    }

    @Test("IPv6 CIDR blocks contain exactly the addresses sharing their first p bits, in every spelling, and every spelling has the RFC 5952 canonical form (10,000 seeded blocks)", .timeLimit(.minutes(2)))
    func cidrV6() throws {
        var rng = SplitMix64(seed: Self.cidrSeed &+ 1)
        func groups() -> [UInt16] {
            (0..<8).map { _ in rng.chance(45) ? 0 : UInt16.random(in: 0...UInt16.max, using: &rng) }
        }
        func isMapped(_ g: [UInt16]) -> Bool { g[0..<5].allSatisfy { $0 == 0 } && g[5] == 0xFFFF }
        func high(_ g: [UInt16]) -> UInt64 { g[0..<4].reduce(0) { $0 << 16 | UInt64($1) } }
        func low(_ g: [UInt16]) -> UInt64 { g[4..<8].reduce(0) { $0 << 16 | UInt64($1) } }
        func share(_ a: [UInt16], _ b: [UInt16], prefix: Int) -> Bool {
            let highBits = min(prefix, 64)
            let lowBits = max(prefix - 64, 0)
            let highMask: UInt64 = highBits == 0 ? 0 : ~(UInt64.max >> UInt64(highBits))
            let lowMask: UInt64 = lowBits == 0 ? 0 : ~(UInt64.max >> UInt64(lowBits))
            return (high(a) ^ high(b)) & highMask == 0 && (low(a) ^ low(b)) & lowMask == 0
        }
        var tested = 0
        for index in 0..<Self.cidrCases {
            let network = groups()
            if isMapped(network) { continue }
            let prefix = rng.int(1...128)
            let full = network.map { paddedHex(UInt64($0), width: 4) }.joined(separator: ":")                 // upper case, all leading zeros
            let block = try NetworkBlock("\(full)/\(prefix)")
            #expect(try NetworkBlock("\(Self.rfc5952(network))/\(prefix)") == block, "case \(index) seed \(Self.cidrSeed &+ 1): two spellings, two blocks")
            #expect(NetworkBlock.canonicalAddress(full) == Self.rfc5952(network), "case \(index): canonical form of \(full)")
            for probeIndex in 0..<8 {
                var probe = groups()
                if probeIndex % 2 == 0 {
                    probe = network
                    let bit = rng.int(0...127)
                    probe[bit / 16] ^= UInt16(1) << UInt16(15 - bit % 16)                                  // one bit away
                }
                if isMapped(probe) { continue }
                let expected = share(probe, network, prefix: prefix)
                #expect(block.contains(Self.rfc5952(probe)) == expected, "case \(index) seed \(Self.cidrSeed &+ 1): \(block) \(Self.rfc5952(probe))")
                #expect(block.contains(probe.map { String($0, radix: 16) }.joined(separator: ":")) == expected, "uncompressed spelling")
                tested += 1
            }
        }
        #expect(tested > 40_000, "most generated blocks are testable (\(tested) probes)")
        recordMeasurement("CIDR v6 fuzz", "\(Self.cidrCases) blocks, \(tested) probes, seed \(Self.cidrSeed &+ 1)")
    }

    static let cidrGarbageCases = 30_000

    @Test("Garbage CIDR text never traps; what parses survives being printed and parsed again; prefixes outside 1...bits are refused (30,000 seeded strings)", .timeLimit(.minutes(2)))
    func cidrGarbage() throws {
        var rng = SplitMix64(seed: Self.cidrSeed &+ 2)
        let pieces = ["0", "1", "10", "255", "256", "999", "00", "01", ".", ".", ":", "::", "a", "f", "ffff", "g", "/", "/", "8", "24", "32", "33", "128", "129", "-", "+", " ", "%", "[", "]", "ffff:", "::ffff:", "1.2.3.4", "2001:db8"]
        var parsed = 0
        for index in 0..<Self.cidrGarbageCases {
            var text = ""
            for _ in 0..<rng.int(0...9) { text += rng.pick(pieces) }
            if let block = try? NetworkBlock(text) {
                parsed += 1
                #expect((try? NetworkBlock(block.description)) == block, "case \(index) seed \(Self.cidrSeed &+ 2): \(text.debugDescription) printed as \(block) does not parse back to itself")
            }
            if let canonical = NetworkBlock.canonicalAddress(text) {
                #expect(NetworkBlock.isAddress(text))
                #expect(NetworkBlock.canonicalAddress(canonical) == canonical, "case \(index): canonical form is not a fixed point: \(canonical)")
            } else {
                #expect(!NetworkBlock.isAddress(text), "case \(index): isAddress and canonicalAddress disagree on \(text.debugDescription)")
            }
        }
        #expect(parsed > 100, "the generator should reach the accepting path (\(parsed))")
        for refused in ["10.0.0.0/0", "10.0.0.0/33", "::1/0", "::1/129", "10.0.0.0/-1", "10.0.0.0/+8", "010.0.0.1", "10.0.0.0/", "/8", "10.0.0.0/8/8", ""] {
            #expect((try? NetworkBlock(refused)) == nil, "\(refused.debugDescription) must be refused")
        }
        recordMeasurement("CIDR garbage fuzz", "\(Self.cidrGarbageCases) cases, seed \(Self.cidrSeed &+ 2), \(parsed) parsed")
    }
}
