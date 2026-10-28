// SharedRules.swift
// SwiftHTTPServiceNIO
//
// The rules that do not depend on which version of HTTP carried the request, so HTTP/1.1 and HTTP/2 apply
// the same ones.

import Foundation
import HTTPTypes
import SwiftHTTPService

/// What makes a request acceptable, whatever carried it.
enum RequestRules {

    /// A field value with a CR, LF or NUL in it can be read two ways by two parties.
    static func isCleanFieldValue(_ value: String) -> Bool {
        !value.utf8.contains { $0 == 0 || $0 == 0x0A || $0 == 0x0D }
    }

    /// A Content-Length is ASCII digits and nothing else (surrounding whitespace aside): no sign, no
    /// hexadecimal, no list, and small enough to be a real length.
    static func parseLength(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return nil
        }
        return Int(trimmed)
    }

    /// Whether the core's strict origin-form parse accepts this target. Checked before any body is read, so
    /// a refused target costs nothing.
    static func isAcceptableTarget(method: HTTPRequest.Method, target: String, fields: HTTPFields) -> Bool {
        let parsed = Result { try Request(method: method, target: target, headers: fields, body: Data()) }
        guard case .success = parsed else { return false }
        return true
    }

    /// Whether a declared body length is within the bound.
    static func declaredLengthFits(_ length: Int, limit: Int) -> Bool { length <= limit }

    /// Whether a body that has `received` bytes can take `incoming` more without passing the bound.
    static func bodyFits(received: Int, incoming: Int, limit: Int) -> Bool { received + incoming <= limit }
}

/// What a handler's outcome means for the response, whatever carries it.
enum ResponseRules {

    /// A response ready to be written: its final status, the fields the handler may set, and whether the
    /// status allows a body.
    struct Prepared: Equatable {
        var code: Int
        /// The handler's fields, minus those the transport owns (`Content-Length`, `Date`) and those that
        /// are about a connection and not a message (`Connection`, `Keep-Alive`, `Transfer-Encoding`).
        var fields: [HTTPField]
        var hasBody: Bool
        var body: Data
    }

    /// The handler's result as a response, or the refusal that stands in for it. A thrown error, or a
    /// status that is not a final one, is an internal error, and the text of an error is never sent.
    static func outcome(of result: Result<Response, any Error>) -> Result<Response, Refusal> {
        switch result {
        case .success(let response) where (200...599).contains(response.status.code): .success(response)
        case .success, .failure: .failure(.internalError)
        }
    }

    /// The fields and body to write for `response`. A body is dropped for 1xx, 204 and 304, and the
    /// caller decides whether a HEAD request gets it.
    static func prepare(_ response: Response) -> Prepared {
        let owned: Set<String> = ["content-length", "connection", "date", "transfer-encoding", "keep-alive"]
        let fields = response.headers.filter { !owned.contains($0.name.rawName.lowercased()) }
        let code = response.status.code
        let hasBody = !(code < 200 || code == 204 || code == 304)
        return Prepared(code: code, fields: Array(fields), hasBody: hasBody, body: response.body)
    }
}

extension Refusal {
    /// The `application/problem+json` response for this refusal.
    var response: Response {
        var fields = HTTPFields()
        fields[.contentType] = "application/problem+json"
        return Response(status: HTTPResponse.Status(code: statusCode), headers: fields, body: body)
    }
}
