// Context.swift
// SwiftHTTPService
//
// What middleware learns about a request, for the handlers after it.

/// A key for a value carried in a request's ``Context``.
///
/// The key is a type, so two keys never collide and a read needs no cast:
///
/// ```swift
/// enum Subject: ContextKey { typealias Value = String }
/// var context = Context()
/// context[Subject.self] = "alice"
/// ```
public protocol ContextKey {
    /// The type of value stored under this key.
    associatedtype Value: Sendable
}

/// Typed values that middleware attach to a request: the request id, the authenticated subject, the tenant.
public struct Context: Sendable {
    private var values: [ObjectIdentifier: any Sendable] = [:]

    /// Creates an empty context.
    public init() {}

    /// The value stored under `key`, or nil. Assigning nil removes it.
    public subscript<Key: ContextKey>(_ key: Key.Type) -> Key.Value? {
        get { values[ObjectIdentifier(key)] as? Key.Value }
        set { values[ObjectIdentifier(key)] = newValue }
    }
}
