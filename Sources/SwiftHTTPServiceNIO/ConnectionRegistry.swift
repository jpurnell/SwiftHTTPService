// ConnectionRegistry.swift
// SwiftHTTPServiceNIO
//
// Which connections are open, and the cap on them.

import NIOConcurrencyHelpers
import NIOCore

/// The open connections of one server: the cap, the means to close them all, and a second, small cap on the
/// connections being refused.
///
/// Admission is atomic with the count, so the cap holds however many connections arrive at once. A connection
/// over the cap is not served: it is told the server is busy (``BusyRefusalHandler``) if one of a few refusal
/// slots is free, and closed with nothing written if none is. The slots are the bound on the cost of
/// refusing: a refusal that could be had without limit would be a way to spend the server's threads and
/// descriptors in exactly the moment it has none to spare, so past `defaultRefusalSlots` connections being
/// refused at once the server goes back to closing at once.
///
/// Draining and waiting for connections to end are NIOExtras' `ServerQuiescingHelper`'s job, not this
/// type's; this one exists because a cap needs a count and the end of a grace period needs the channels.
final class ConnectionRegistry: Sendable {
    /// What to do with a connection that has just arrived.
    enum Admission: Equatable {
        /// Serve it. It is recorded, and ``remove(_:)`` must be called when it closes.
        case admitted
        /// Tell it the server is busy and close it. A refusal slot is held, and ``endRefusal()`` must be called when it closes.
        case refuse
        /// Close it with nothing written.
        case drop
    }

    /// How many connections may be being refused at once. Small on purpose: each holds a descriptor and a timer
    /// for at most ``BusyRefusalHandler/deadline``, and a server at its cap is a server with none to spare.
    static let defaultRefusalSlots = 32

    private struct State {
        var channels: [ObjectIdentifier: any Channel] = [:]
        var refusing = 0
    }

    private let maximum: Int
    private let refusalSlots: Int
    private let state = NIOLockedValueBox(State())

    init(maximum: Int, refusalSlots: Int = ConnectionRegistry.defaultRefusalSlots) {
        self.maximum = maximum
        self.refusalSlots = refusalSlots
    }

    /// Decides what to do with `channel`, and records it if it is to be served. With `mayRefuse` false (a
    /// connection that would have to be refused over TLS, where an answer costs a handshake) a connection over
    /// the cap is dropped, never refused.
    func admit(_ channel: any Channel, mayRefuse: Bool = true) -> Admission {
        state.withLockedValue { state in
            guard state.channels.count < maximum else {
                guard mayRefuse, state.refusing < refusalSlots else { return .drop }
                state.refusing += 1
                return .refuse
            }
            state.channels[ObjectIdentifier(channel)] = channel
            return .admitted
        }
    }

    /// Forgets `channel`.
    func remove(_ channel: any Channel) {
        state.withLockedValue { _ = $0.channels.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    /// A refused connection has closed: its slot is free.
    func endRefusal() {
        state.withLockedValue { $0.refusing = max(0, $0.refusing - 1) }
    }

    /// How many connections are open.
    var count: Int { state.withLockedValue { $0.channels.count } }

    /// How many connections are being refused.
    var refusing: Int { state.withLockedValue { $0.refusing } }

    /// Closes every open connection now.
    func closeAll() {
        let open = state.withLockedValue { Array($0.channels.values) }
        for channel in open { channel.close(promise: nil) }
    }
}
