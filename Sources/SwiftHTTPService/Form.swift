// Form.swift
// SwiftHTTPService
//
// application/x-www-form-urlencoded, parsed strictly.

import Foundation
import HTTPTypes

/// A form body that was refused. It never carries the body or a field.
public enum FormError: Error, Equatable, Sendable {
    /// The request is not `application/x-www-form-urlencoded` (or names a charset other than UTF-8).
    case contentType
    /// The body is not well formed: a `%` without two hex digits, a raw space or control or non-ASCII byte, an
    /// empty segment or name, or a NUL.
    case malformed
    /// A name or value is not valid UTF-8 once decoded.
    case encoding
    /// More fields than allowed.
    case tooManyFields
    /// A name or value is longer than allowed, in decoded bytes.
    case fieldTooLong
}

/// One decoded `name=value` pair.
public struct FormField: Sendable, Equatable {
    /// The name, decoded.
    public let name: String
    /// The value, decoded. Empty for a field with no `=` or nothing after it.
    public let value: String
}

/// A parsed form: its fields in the order sent, duplicates kept.
public struct Form: Sendable, Equatable {
    /// The fields.
    public let fields: [FormField]

    /// The value of the first field called `name` (case-sensitive), or nil.
    public func first(_ name: String) -> String? {
        fields.first { $0.name == name }?.value
    }

    /// Every value for `name`, in the order sent.
    public func all(_ name: String) -> [String] {
        fields.filter { $0.name == name }.map(\.value)
    }
}

extension Request {
    /// Parses the body as `application/x-www-form-urlencoded`, strictly.
    ///
    /// A browser percent-encodes everything outside the unreserved set and writes a space as `+`, so a body that
    /// holds a raw space, a control or non-ASCII byte, a `%` not followed by two hex digits, an empty segment
    /// (`a=1&&b=2`, a leading or trailing `&`), an empty name or a decoded NUL is something other than a form,
    /// or a form two parsers could read two ways, and is refused. An empty body is an empty form; a request that
    /// is not a form at all is ``FormError/contentType``, never an empty form.
    ///
    /// Only the first `=` splits a field, so a value may hold `=`. Duplicates are kept, in order, and the handler
    /// decides what they mean. `multipart/form-data` is not handled.
    ///
    /// - Parameters:
    ///   - maximumFields: The most fields. Default 100.
    ///   - maximumFieldLength: The longest name or value, in decoded bytes. Default 8 KiB.
    /// - Throws: ``FormError``. The body is bounded already by the transport's body limit.
    public func form(maximumFields: Int = 100, maximumFieldLength: Int = 8192) throws(FormError) -> Form {
        guard Self.isFormContentType(headers[.contentType]) else { throw .contentType }
        let bytes = [UInt8](body)
        guard bytes.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { throw .malformed }
        guard !bytes.isEmpty else { return Form(fields: []) }
        var fields: [FormField] = []
        for segment in bytes.split(separator: 0x26, omittingEmptySubsequences: false) {
            guard !segment.isEmpty else { throw .malformed }
            guard fields.count < maximumFields else { throw .tooManyFields }
            let equals = segment.firstIndex(of: 0x3D)
            let rawName = equals.map { segment[segment.startIndex..<$0] } ?? segment
            let rawValue = equals.map { segment[segment.index(after: $0)...] } ?? segment[segment.endIndex...]
            let name = try Self.decode(rawName, maximumLength: maximumFieldLength)
            guard !name.isEmpty else { throw .malformed }
            fields.append(FormField(name: name, value: try Self.decode(rawValue, maximumLength: maximumFieldLength)))
        }
        return Form(fields: fields)
    }

    /// `application/x-www-form-urlencoded`, in any case, with at most a `charset=utf-8` parameter.
    private static func isFormContentType(_ value: String?) -> Bool {
        guard let value else { return false }
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.first == "application/x-www-form-urlencoded" else { return false }
        switch parts.count {
        case 1: return true
        case 2: return parts[1] == "charset=utf-8" || parts[1] == "charset=\"utf-8\""
        default: return false
        }
    }

    private static func decode(_ raw: ArraySlice<UInt8>, maximumLength: Int) throws(FormError) -> String {
        var decoded: [UInt8] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let byte = raw[index]
            switch byte {
            case 0x2B:
                decoded.append(0x20)
                index += 1
            case 0x25:
                guard index + 2 < raw.endIndex, let high = hexValue(raw[index + 1]), let low = hexValue(raw[index + 2]) else {
                    throw .malformed
                }
                decoded.append(high << 4 | low)
                index += 3
            default:
                decoded.append(byte)
                index += 1
            }
        }
        guard !decoded.contains(0) else { throw .malformed }
        guard decoded.count <= maximumLength else { throw .fieldTooLong }
        // Decoding repairs invalid UTF-8 with U+FFFD, so the text matches the bytes only if they were valid.
        let text = String(decoding: decoded, as: UTF8.self)
        guard Array(text.utf8) == decoded else { throw .encoding }
        return text
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
