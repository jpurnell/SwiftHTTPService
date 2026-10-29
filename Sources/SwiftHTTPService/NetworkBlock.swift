// NetworkBlock.swift
// SwiftHTTPService
//
// A range of addresses, for naming the proxies a server trusts.

import Foundation

/// A block of IP addresses in CIDR form: `10.0.0.0/8`, `2001:db8::/32`, or a single host (`198.51.100.9`, `::1`).
///
/// Used to say which peers are trusted proxies. A block holds the addresses that share its first `prefix` bits.
/// Host bits in the text are ignored (`10.1.2.3/24` is `10.1.2.0/24`). The block of every address (`/0`) is
/// refused: trusting it is trusting nobody in particular. An IPv4 address written as IPv4-mapped IPv6
/// (`::ffff:10.1.2.3`) is that IPv4 address when it is tested against a block; as a block it is refused, so write
/// the IPv4 form.
public struct NetworkBlock: Sendable, Equatable, CustomStringConvertible {
    /// The network address with its host bits cleared: 4 octets (IPv4) or 16 (IPv6).
    private let network: [UInt8]
    private let prefix: Int

    /// Parses a block.
    ///
    /// - Throws: ``ConfigurationError`` naming `trustedProxies` with reason `malformed`. It never carries the text.
    public init(_ text: String) throws(ConfigurationError) {
        let refusal = ConfigurationError(field: "trustedProxies", reason: .malformed)
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let bytes = Self.octets(of: String(parts[0]), mappedAsIPv4: false) else { throw refusal }
        var prefix = bytes.count * 8
        if parts.count == 2 {
            let digits = parts[1]
            guard digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let value = Int(digits),
                  (1...bytes.count * 8).contains(value)
            else { throw refusal }
            prefix = value
        }
        self.network = Self.masked(bytes, prefix: prefix)
        self.prefix = prefix
    }

    /// Whether `address`, an IPv4 or IPv6 literal, is in the block. Anything that is not an address is in no block.
    public func contains(_ address: String) -> Bool {
        guard let octets = Self.octets(of: address, mappedAsIPv4: true), octets.count == network.count else { return false }
        return Self.masked(octets, prefix: prefix) == network
    }

    /// Whether `text` is an IPv4 or IPv6 address literal on its own: no prefix, no port, no brackets.
    public static func isAddress(_ text: String) -> Bool {
        octets(of: text, mappedAsIPv4: true) != nil
    }

    /// The one canonical text of an address literal, or nil if `text` is not one: IPv4 dotted, IPv6 in the RFC 5952
    /// form, and an IPv4-mapped IPv6 address as the IPv4 address it names. Two spellings of one address therefore
    /// become one string, which is what a rate limit or a log should key on.
    public static func canonicalAddress(_ text: String) -> String? {
        octets(of: text, mappedAsIPv4: true).flatMap(canonicalAddress(octets:))
    }

    /// The canonical text of an address given as 4 (IPv4) or 16 (IPv6) octets, or nil for any other length.
    public static func canonicalAddress(octets: [UInt8]) -> String? {
        switch octets.count {
        case 4:
            return text(ofIPv4: octets)
        case 16:
            let isMapped = octets[0..<10].allSatisfy { $0 == 0 } && octets[10] == 0xFF && octets[11] == 0xFF
            return isMapped ? text(ofIPv4: Array(octets[12...])) : text(ofIPv6: octets)
        default:
            return nil
        }
    }

    /// The block with an explicit prefix: `10.1.2.0/24`, `198.51.100.9/32`, `fd00::/8`. IPv6 is written the way
    /// RFC 5952 recommends: lower case, no leading zeros, the longest run of zero groups as `::`.
    public var description: String {
        let text = network.count == 4 ? Self.text(ofIPv4: network) : Self.text(ofIPv6: network)
        return "\(text)/\(prefix)"
    }

    // MARK: Parsing

    /// The octets of an address literal, or nil. An IPv4-mapped IPv6 address becomes its 4 IPv4 octets when
    /// `mappedAsIPv4`, and is refused (nil) otherwise.
    private static func octets(of text: String, mappedAsIPv4: Bool) -> [UInt8]? {
        if let four = ipv4(text) { return four }
        guard let six = ipv6(text) else { return nil }
        let isMapped = six[0..<10].allSatisfy { $0 == 0 } && six[10] == 0xFF && six[11] == 0xFF
        if isMapped { return mappedAsIPv4 ? Array(six[12...]) : nil }
        return six
    }

    /// Four decimal octets separated by dots. No leading zeros (a leading zero is octal to some parsers and
    /// decimal to others, so it names two addresses), no sign, each at most 255. (`UInt8` refuses an empty part and
    /// anything over three digits.)
    private static func ipv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), part.utf8.count == 1 || part.utf8.first != 0x30,
                  let value = UInt8(part)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Eight groups of one to four hex digits separated by colons, with at most one `::` standing for one or more
    /// zero groups, and optionally an IPv4 address as the last 32 bits. No zone (`%eth0`), no brackets, no port.
    private static func ipv6(_ text: String) -> [UInt8]? {
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        let compressed = halves.count == 2
        var groups: [[UInt8]] = []            // each group is 2 octets, in order
        var sides: [[[UInt8]]] = []
        for (index, half) in halves.enumerated() {
            var side: [[UInt8]] = []
            if !half.isEmpty {
                let pieces = half.split(separator: ":", omittingEmptySubsequences: false)
                for (position, piece) in pieces.enumerated() {
                    let isLastOfAddress = position == pieces.count - 1 && index == halves.count - 1
                    if isLastOfAddress, piece.contains("."), let four = ipv4(String(piece)) {
                        side.append([four[0], four[1]])
                        side.append([four[2], four[3]])
                        continue
                    }
                    guard let value = hexGroup(piece) else { return nil }
                    side.append([UInt8(value >> 8), UInt8(value & 0xFF)])
                }
            }
            sides.append(side)
        }
        let present = sides.reduce(0) { $0 + $1.count }
        if compressed {
            guard present <= 7 else { return nil }
            groups = sides[0] + Array(repeating: [0, 0], count: 8 - present) + sides[1]
        } else {
            guard present == 8 else { return nil }
            groups = sides[0]
        }
        return groups.flatMap { $0 }
    }

    /// One to four hex digits as a number, or nil. Only the digits 0-9, a-f and A-F: no sign, no `0x`.
    private static func hexGroup(_ piece: Substring) -> UInt16? {
        guard (1...4).contains(piece.utf8.count) else { return nil }
        var value: UInt16 = 0
        for byte in piece.utf8 {
            let digit: UInt16
            switch byte {
            case 0x30...0x39: digit = UInt16(byte - 0x30)
            case 0x41...0x46: digit = UInt16(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt16(byte - 0x61 + 10)
            default: return nil
            }
            value = value << 4 | digit
        }
        return value
    }

    private static func text(ofIPv4 octets: [UInt8]) -> String {
        octets.map { String($0) }.joined(separator: ".")
    }

    private static func text(ofIPv6 octets: [UInt8]) -> String {
        let groups = stride(from: 0, to: 16, by: 2).map { UInt16(octets[$0]) << 8 | UInt16(octets[$0 + 1]) }
        // The longest run of zero groups, at least two long, the first if there is a tie, becomes "::".
        var best = (start: -1, length: 0)
        var index = 0
        while index < 8 {
            guard groups[index] == 0 else { index += 1; continue }
            var end = index
            while end < 8, groups[end] == 0 { end += 1 }
            if end - index > best.length { best = (index, end - index) }
            index = end
        }
        let hex = groups.map { String($0, radix: 16) }
        guard best.length >= 2 else { return hex.joined(separator: ":") }
        let before = hex[0..<best.start].joined(separator: ":")
        let after = hex[(best.start + best.length)...].joined(separator: ":")
        return before + "::" + after
    }

    private static func masked(_ octets: [UInt8], prefix: Int) -> [UInt8] {
        var result = octets
        for index in result.indices {
            let bitsKept = max(0, min(8, prefix - index * 8))
            result[index] = bitsKept == 0 ? 0 : result[index] & UInt8(truncatingIfNeeded: 0xFF << (8 - bitsKept))
        }
        return result
    }
}
