import Foundation
import HTTPTypes
import Testing
@testable import SwiftHTTPService

/// `application/x-www-form-urlencoded`, parsed strictly. Expected values are worked out by hand from the HTML
/// form-encoding rules (a `+` is a space, `%XX` is one byte, names and values are UTF-8), not read from the code.
@Suite("Form bodies")
struct FormTests {

    private static func request(
        _ body: String, contentType: String? = "application/x-www-form-urlencoded", bytes: [UInt8]? = nil
    ) throws -> Request {
        var headers = HTTPFields()
        if let contentType { headers[.contentType] = contentType }
        return try Request(method: .post, target: "/authorize", headers: headers, body: Data(bytes ?? Array(body.utf8)))
    }

    // MARK: What parses

    struct Good: Sendable, CustomTestStringConvertible {
        let body: String
        let fields: [[String]]
        var testDescription: String { body.debugDescription }
    }

    static let good: [Good] = [
        Good(body: "", fields: []),
        Good(body: "a=1", fields: [["a", "1"]]),
        Good(body: "a=1&b=2", fields: [["a", "1"], ["b", "2"]]),
        Good(body: "a=", fields: [["a", ""]]),
        Good(body: "a", fields: [["a", ""]]),                                  // no "=": a name with an empty value
        Good(body: "a=1=2", fields: [["a", "1=2"]]),                           // only the first "=" splits
        Good(body: "a=hello+world", fields: [["a", "hello world"]]),           // "+" is a space
        Good(body: "a=hello%20world", fields: [["a", "hello world"]]),
        Good(body: "a=%2B", fields: [["a", "+"]]),                             // an encoded plus stays a plus
        Good(body: "a=%26%3D%25", fields: [["a", "&=%"]]),
        Good(body: "a=%c3%a9", fields: [["a", "é"]]),                          // lower-case hex, UTF-8 for é
        Good(body: "a=%C3%A9", fields: [["a", "é"]]),
        Good(body: "a=%09%0a%7E%20", fields: [["a", "\t\n~ "]]),               // tab, newline, ~ and a space: the digits 0, 9, a and E in use
        Good(body: "a=%41%61%46%66", fields: [["a", "AaFf"]]),                  // 0x41 A, 0x61 a, 0x46 F, 0x66 f
        Good(body: "a=%E2%82%AC", fields: [["a", "€"]]),                       // three bytes
        Good(body: "%C3%A9=1", fields: [["é", "1"]]),                          // names decode the same way
        Good(body: "a=1&a=2&a=3", fields: [["a", "1"], ["a", "2"], ["a", "3"]]),   // duplicates are kept, in order
        Good(body: "user=alice&redirect=%2Fhome%3Fx%3D1", fields: [["user", "alice"], ["redirect", "/home?x=1"]]),
    ]

    @Test("A body is split into its fields, decoded, in order, with duplicates kept", arguments: good)
    func parses(_ c: Good) throws {
        let form = try Self.request(c.body).form()
        #expect(form.fields.map { [$0.name, $0.value] } == c.fields)
    }

    @Test("The content type may carry a charset of utf-8 and any case, and nothing else")
    func contentTypeForms() throws {
        for type in ["application/x-www-form-urlencoded", "Application/X-WWW-Form-Urlencoded",
                     "application/x-www-form-urlencoded; charset=utf-8", "application/x-www-form-urlencoded;charset=UTF-8"] {
            #expect(try Self.request("a=1", contentType: type).form().fields.count == 1, "\(type)")
        }
    }

    // MARK: What is refused

    struct Bad: Sendable, CustomTestStringConvertible {
        let name: String
        let request: @Sendable () throws -> Request
        let error: FormError
        var testDescription: String { name }
    }

    static let bad: [Bad] = [
        Bad(name: "no content type", request: { try request("a=1", contentType: nil) }, error: .contentType),
        Bad(name: "JSON", request: { try request("a=1", contentType: "application/json") }, error: .contentType),
        Bad(name: "multipart", request: { try request("a=1", contentType: "multipart/form-data; boundary=x") }, error: .contentType),
        Bad(name: "a lookalike type", request: { try request("a=1", contentType: "application/x-www-form-urlencoded-x") }, error: .contentType),
        Bad(name: "another charset", request: { try request("a=1", contentType: "application/x-www-form-urlencoded; charset=iso-8859-1") }, error: .contentType),
        Bad(name: "a lone %", request: { try request("a=%") }, error: .malformed),
        Bad(name: "a % with one digit", request: { try request("a=%4") }, error: .malformed),
        Bad(name: "a % with non-hex digits", request: { try request("a=%zz") }, error: .malformed),
        // The characters just outside each hex range are not digits: 0x2F/0x3A around 0-9, 0x40/0x47 around A-F, 0x60/0x67 around a-f.
        Bad(name: "% then /", request: { try request("a=%/0") }, error: .malformed),
        Bad(name: "% then :", request: { try request("a=%:0") }, error: .malformed),
        Bad(name: "% then @", request: { try request("a=%@0") }, error: .malformed),
        Bad(name: "% then G", request: { try request("a=%G0") }, error: .malformed),
        Bad(name: "% then a backtick", request: { try request("a=%`0") }, error: .malformed),
        Bad(name: "% then g", request: { try request("a=%g0") }, error: .malformed),
        Bad(name: "% then a good digit and G", request: { try request("a=%0G") }, error: .malformed),
        Bad(name: "% then a good digit and g", request: { try request("a=%0g") }, error: .malformed),
        Bad(name: "two content type parameters", request: { try request("a=1", contentType: "application/x-www-form-urlencoded; charset=utf-8; x=y") }, error: .contentType),
        Bad(name: "a % with a sign", request: { try request("a=%+1") }, error: .malformed),
        Bad(name: "an empty segment between fields", request: { try request("a=1&&b=2") }, error: .malformed),
        Bad(name: "a trailing &", request: { try request("a=1&") }, error: .malformed),
        Bad(name: "a leading &", request: { try request("&a=1") }, error: .malformed),
        Bad(name: "an empty name", request: { try request("=1") }, error: .malformed),
        Bad(name: "an encoded NUL", request: { try request("a=%00") }, error: .malformed),
        Bad(name: "a raw space", request: { try request("a=1 2") }, error: .malformed),
        Bad(name: "a raw newline", request: { try request("a=1\n") }, error: .malformed),
        Bad(name: "a raw non-ASCII byte", request: { try request("", bytes: Array("a=é".utf8)) }, error: .malformed),
        Bad(name: "a raw DEL", request: { try request("", bytes: [0x61, 0x3D, 0x7F]) }, error: .malformed),
        Bad(name: "invalid UTF-8 (a lone continuation byte)", request: { try request("a=%80") }, error: .encoding),
        Bad(name: "invalid UTF-8 (a truncated sequence)", request: { try request("a=%C3") }, error: .encoding),
        Bad(name: "invalid UTF-8 (an overlong NUL)", request: { try request("a=%C0%80") }, error: .encoding),
        Bad(name: "invalid UTF-8 in a name", request: { try request("%FF=1") }, error: .encoding),
    ]

    @Test("A body that could be read two ways, or is not what it says, is refused", arguments: bad)
    func refuses(_ c: Bad) {
        #expect(throws: c.error) { _ = try c.request().form() }
    }

    // MARK: Bounds

    @Test("At most the given number of fields: the bound is accepted, one more is refused")
    func fieldCount() throws {
        let three = "a=1&b=2&c=3"
        #expect(try Self.request(three).form(maximumFields: 3).fields.count == 3)
        #expect(throws: FormError.tooManyFields) { _ = try Self.request(three).form(maximumFields: 2) }
        #expect(throws: FormError.tooManyFields) { _ = try Self.request("a=1").form(maximumFields: 0) }
        #expect(try Self.request("").form(maximumFields: 0).fields.isEmpty)
    }

    @Test("A name or value longer than the bound, counted in decoded bytes, is refused; one at the bound is accepted")
    func fieldLength() throws {
        #expect(try Self.request("a=12345").form(maximumFieldLength: 5).fields.count == 1)
        #expect(throws: FormError.fieldTooLong) { _ = try Self.request("a=123456").form(maximumFieldLength: 5) }
        #expect(throws: FormError.fieldTooLong) { _ = try Self.request("abcdef=1").form(maximumFieldLength: 5) }
        // "é" is two bytes once decoded, however it was spelled: three of them are six.
        #expect(throws: FormError.fieldTooLong) { _ = try Self.request("a=%C3%A9%C3%A9%C3%A9").form(maximumFieldLength: 5) }
        #expect(try Self.request("a=%C3%A9%C3%A9").form(maximumFieldLength: 4).fields.count == 1)
    }

    @Test("The bounds default to 100 fields of 8 KiB")
    func defaultBounds() throws {
        let hundred = (0..<100).map { "k\($0)=v" }.joined(separator: "&")
        #expect(try Self.request(hundred).form().fields.count == 100)
        #expect(throws: FormError.tooManyFields) { _ = try Self.request(hundred + "&x=1").form() }
        #expect(try Self.request("a=" + String(repeating: "x", count: 8192)).form().fields.count == 1)
        #expect(throws: FormError.fieldTooLong) { _ = try Self.request("a=" + String(repeating: "x", count: 8193)).form() }
    }

    // MARK: Reading a form

    @Test("A field is found by name: the first value, or all of them in order")
    func lookup() throws {
        let form = try Self.request("a=1&b=2&a=3").form()
        #expect(form.first("a") == "1")
        #expect(form.all("a") == ["1", "3"])
        #expect(form.first("missing") == nil)
        #expect(form.all("missing").isEmpty)
        #expect(form.first("A") == nil)                 // names are case-sensitive
    }

    @Test("A GET with no body and no content type is an error, not an empty form")
    func notAnEmptyForm() throws {
        let request = try Request(method: .get, target: "/x", headers: HTTPFields(), body: Data())
        #expect(throws: FormError.contentType) { _ = try request.form() }
    }
}
