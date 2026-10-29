// AccessLog.swift
// SwiftHTTPService
//
// One entry per request, and a line that cannot be forged.

import HTTPTypes

/// What is recorded about one request.
///
/// There is deliberately no query string, no header and no body here: a query can hold a token, a header an
/// `Authorization`, a body anything. The path is the strict origin-form path the core already validated.
public struct AccessLogEntry: Sendable, Equatable {
    /// The request method, as sent.
    public let method: String
    /// The path, without the query.
    public let path: String
    /// The response status. `500` for a handler that threw.
    public let status: Int
    /// The size of the response body, in bytes.
    public let responseBytes: Int
    /// How long the request took, from the moment the layer saw it to the moment the response came back.
    public let duration: Duration
    /// The request id, if one was set (see ``requestID(header:generate:)``).
    public let requestID: String?
    /// The peer's address, if the transport knows it.
    public let remoteAddress: String?

    /// Creates an entry.
    public init(
        method: String, path: String, status: Int, responseBytes: Int, duration: Duration, requestID: String?, remoteAddress: String?
    ) {
        self.method = method
        self.path = path
        self.status = status
        self.responseBytes = responseBytes
        self.duration = duration
        self.requestID = requestID
        self.remoteAddress = remoteAddress
    }

    /// The entry as one line of `key=value` pairs, in a fixed order, every text value quoted and escaped.
    ///
    /// Anything that is not printable ASCII, and the quote and the backslash, is written as an escape
    /// (`\xNN`, or `\u{...}` above U+00FF), so no value can end its own field, start a second line, or
    /// carry a control sequence to whoever reads the log.
    public var line: String {
        [
            "method=\(Self.quoted(method))",
            "path=\(Self.quoted(path))",
            "status=\(status)",
            "bytes=\(responseBytes)",
            "duration_ms=\(Self.milliseconds(duration))",
            "request_id=\(Self.quoted(requestID ?? "-"))",
            "remote=\(Self.quoted(remoteAddress ?? "-"))",
        ].joined(separator: " ")
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x20...0x7E: out.unicodeScalars.append(scalar)
            case 0..<0x100: out += "\\x" + hex(scalar.value, width: 2)
            default: out += "\\u{" + hex(scalar.value, width: 4) + "}"
            }
        }
        return out + "\""
    }

    private static func hex(_ value: UInt32, width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// Whole milliseconds, rounded down, and never negative.
    private static func milliseconds(_ duration: Duration) -> Int {
        guard duration >= .zero else { return 0 }
        let parts = duration.components
        let (fromSeconds, overflow) = Int(parts.seconds).multipliedReportingOverflow(by: 1000)
        guard !overflow else { return Int.max }
        return fromSeconds + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

private let processStart = ContinuousClock.now

/// Records one ``AccessLogEntry`` for every request that passes through.
///
/// The sink is a closure so the kit chooses no logging library; it is called once per request, after the
/// response is known, on whatever task ran the request, and should not block. A handler that throws is
/// recorded as `500` (the transport's answer) and the error goes on unchanged; its text is never recorded.
///
/// Put it outermost so it sees the responses other layers make, a rate limiter's `429` among them. The request
/// id is read from the request's context if a layer outside this one set it, and otherwise from the response
/// header the ``requestID(header:generate:)`` layer inside this one set; a request that threw has neither.
///
/// - Parameters:
///   - now: A monotonic reading, as the time since some fixed start. Nil means the process's
///     `ContinuousClock`; tests pass a clock they move by hand.
///   - requestIDHeader: The response header the id is read from.
///   - sink: Receives each entry.
public func accessLog(
    now: (@Sendable () -> Duration)? = nil,
    requestIDHeader: HTTPField.Name = .requestID,
    sink: @escaping @Sendable (AccessLogEntry) -> Void
) -> Middleware {
    let now = now ?? { processStart.duration(to: ContinuousClock.now) }
    return { request, next in
        let started = now()
        let record: @Sendable (Int, Int, String?) -> Void = { status, bytes, id in
            sink(AccessLogEntry(
                method: request.method.rawValue, path: request.path, status: status, responseBytes: bytes,
                duration: now() - started, requestID: request.context[RequestID.self] ?? id, remoteAddress: request.remoteAddress))
        }
        let response: Response
        do {
            response = try await next(request)
        } catch {
            record(500, 0, nil)
            throw error
        }
        guard let stream = response.stream else {
            record(response.status.code, response.body.count, response.headers[requestIDHeader])
            return response
        }
        // A streaming response's bytes are not known until it ends, so it is logged then: with the status it began
        // with, the bytes streamed, and the time to the end. A stream that is discarded (HEAD) is logged as it stands.
        let status = response.status.code
        let id = response.headers[requestIDHeader]
        var observed = response
        observed.stream = stream.observing { bytes, _ in record(status, bytes, id) }
        return observed
    }
}
