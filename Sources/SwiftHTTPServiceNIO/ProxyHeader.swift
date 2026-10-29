// ProxyHeader.swift
// SwiftHTTPServiceNIO
//
// The PROXY protocol header a load balancer sends before anything else on a connection.

import SwiftHTTPService

/// A parser for the PROXY protocol header (HAProxy's specification): version 1 as a line of text, version 2 as
/// binary. A pure function of the bytes received so far, so a header that arrives a byte at a time is read the
/// same as one that arrives whole.
///
/// It is strict. A line with a doubled space, a port with a leading zero, an address of the wrong family or with a
/// leading zero, an unknown version, command or family, or a length over the limit is refused outright, because a
/// header that two parsers could read two ways is a way to be told a client is somebody else.
enum ProxyHeader {

    /// What the bytes so far are.
    enum Outcome: Equatable {
        /// A prefix of what could still be a header; wait for more.
        case needMore
        /// A complete header. `client` is the address it names, or nil when it names none (version 1 `UNKNOWN`,
        /// version 2 `LOCAL`, or an address family not carried over TCP/IP); `consumed` is how many bytes it used.
        case header(client: String?, consumed: Int)
        /// Not a header, or a malformed one.
        case invalid
    }

    /// The longest version 1 line, carriage return and line feed included (the specification's 107).
    static let maximumLineLength = 107
    /// The longest version 2 body this server reads. The specification allows 65,535; a header that carries more
    /// than addresses and a few TLVs is not one this server needs, and a bound keeps a connection from buffering.
    static let maximumBodyLength = 1024

    static let v1Prefix = Array("PROXY ".utf8)
    static let v2Signature: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A]

    /// Whether `bytes` could still become a header: they are a prefix of the version 1 start or the version 2
    /// signature (or empty). The way to tell a direct client from one pretending to be a proxy: bytes that cannot
    /// become a header are something else, such as HTTP or a TLS hello.
    static func couldBeginAHeader(_ bytes: [UInt8]) -> Bool {
        /// Either the bytes are the start of `pattern`, or they have all of it and more (so the rest is checked later).
        func agrees(with pattern: [UInt8]) -> Bool {
            bytes.count <= pattern.count ? pattern.starts(with: bytes) : bytes.starts(with: pattern)
        }
        return bytes.isEmpty || agrees(with: v1Prefix) || agrees(with: v2Signature)
    }

    /// Reads a header from the front of `bytes`.
    static func parse(_ bytes: [UInt8]) -> Outcome {
        guard let first = bytes.first else { return .needMore }
        if first == v1Prefix[0] { return parseV1(bytes) }
        if first == v2Signature[0] { return parseV2(bytes) }
        return .invalid
    }

    // MARK: Version 1

    private static func parseV1(_ bytes: [UInt8]) -> Outcome {
        guard v1Prefix.starts(with: bytes.prefix(v1Prefix.count)) else { return .invalid }
        // The line ends at the first carriage return, which must be followed by a line feed, within 107 bytes.
        let window = bytes.prefix(maximumLineLength)
        for (index, byte) in window.enumerated() {
            switch byte {
            case 0x0D:
                guard index + 1 < bytes.count else { return .needMore }        // the line feed has not come yet
                guard bytes[index + 1] == 0x0A, index + 2 <= maximumLineLength else { return .invalid }
                return parseLine(Array(bytes[0..<index]), consumed: index + 2)
            case 0x20...0x7E:
                continue
            default:
                return .invalid                                                // a control byte, a lone line feed, or non-ASCII
            }
        }
        return bytes.count >= maximumLineLength ? .invalid : .needMore
    }

    private static func parseLine(_ line: [UInt8], consumed: Int) -> Outcome {
        let fields = String(decoding: line, as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // fields[0] is "PROXY": the first six bytes were checked against "PROXY " before the line was read.
        guard fields.count >= 2 else { return .invalid }
        switch fields[1] {
        case "UNKNOWN":
            return .header(client: nil, consumed: consumed)             // anything may follow on the line; none of it is used
        case "TCP4", "TCP6":
            guard fields.count == 6 else { return .invalid }
            let isIPv4 = fields[1] == "TCP4"
            guard let source = address(fields[2], isIPv4: isIPv4), address(fields[3], isIPv4: isIPv4) != nil,
                  isPort(fields[4]), isPort(fields[5])
            else { return .invalid }
            return .header(client: source, consumed: consumed)
        default:
            return .invalid
        }
    }

    /// An address of the family the line names, as its canonical text. A leading zero, which is octal to some
    /// parsers and decimal to others, is refused by ``NetworkBlock``.
    private static func address(_ text: String, isIPv4: Bool) -> String? {
        guard text.contains(":") != isIPv4 else { return nil }
        return NetworkBlock.canonicalAddress(text)
    }

    /// A decimal port, 0 to 65535, with no sign and no leading zero. (`Int` refuses an empty string and a number
    /// too large to hold; the range check refuses the rest.)
    private static func isPort(_ text: String) -> Bool {
        guard text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), text.utf8.count == 1 || text.utf8.first != 0x30,
              let value = Int(text)
        else { return false }
        return value <= 65_535
    }

    // MARK: Version 2

    private static func parseV2(_ bytes: [UInt8]) -> Outcome {
        guard v2Signature.starts(with: bytes.prefix(v2Signature.count)) else { return .invalid }
        guard bytes.count >= 16 else { return .needMore }
        let versionAndCommand = bytes[12]
        guard versionAndCommand >> 4 == 2, versionAndCommand & 0x0F <= 1 else { return .invalid }
        let isProxy = versionAndCommand & 0x0F == 1
        let family = bytes[13] >> 4
        let transport = bytes[13] & 0x0F
        guard family <= 3, transport <= 2 else { return .invalid }
        let length = Int(bytes[14]) << 8 | Int(bytes[15])
        guard length <= maximumBodyLength else { return .invalid }
        // The address block must fit in the length given, for the families whose block this server reads.
        let needed: Int
        switch (isProxy, family, transport) {
        case (true, 1, 1): needed = 12
        case (true, 2, 1): needed = 36
        default: needed = 0
        }
        guard length >= needed else { return .invalid }
        guard bytes.count >= 16 + length else { return .needMore }
        let body = bytes[16..<16 + length]
        switch needed {
        case 12:
            return .header(client: NetworkBlock.canonicalAddress(octets: Array(body.prefix(4))), consumed: 16 + length)
        case 36:
            return .header(client: NetworkBlock.canonicalAddress(octets: Array(body.prefix(16))), consumed: 16 + length)
        default:
            return .header(client: nil, consumed: 16 + length)
        }
    }
}
