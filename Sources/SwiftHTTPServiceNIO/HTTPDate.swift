// HTTPDate.swift
// SwiftHTTPServiceNIO
//
// The Date header.

import Foundation

/// Formats the `Date` header (RFC 9110 IMF-fixdate): `Tue, 27 Oct 2026 12:00:00 GMT`.
enum HTTPDate {
    private static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// The header value for `date`. The weekday and month names are fixed English, never localised.
    static func string(for date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        gmtime_r(&seconds, &parts)
        let day = days[Int(parts.tm_wday) % 7]
        let month = months[Int(parts.tm_mon) % 12]
        return "\(day), \(pad(Int(parts.tm_mday))) \(month) \(Int(parts.tm_year) + 1900) "
            + "\(pad(Int(parts.tm_hour))):\(pad(Int(parts.tm_min))):\(pad(Int(parts.tm_sec))) GMT"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
