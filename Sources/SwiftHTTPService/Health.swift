// Health.swift
// SwiftHTTPService
//
// A route for supervisors to probe.

import Foundation

extension Router {

    /// The body of a health response. Constant, so a probe learns nothing but that the process answers.
    static let healthBody = Data(#"{"status":"ok"}"#.utf8)

    /// Registers `GET` (and so `HEAD`) at `path`, answering `200` with a constant JSON body.
    ///
    /// It needs no authentication and reveals nothing: no version, no uptime, no tenant, no count. It says
    /// the process is accepting and answering requests. It does not say the data behind it is fresh; a
    /// server that needs that says it on a route of its own.
    ///
    /// - Throws: ``RouterError``, like any registration.
    public mutating func addHealth(at path: String = "/health") throws(RouterError) {
        try get(path) { _ in
            var response = Response(status: .ok, body: Router.healthBody)
            response.headers[.contentType] = "application/json"
            return response
        }
    }
}
