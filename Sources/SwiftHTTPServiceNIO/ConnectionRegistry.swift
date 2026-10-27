// ConnectionRegistry.swift
// SwiftHTTPServiceNIO
//
// Which connections are open, and the cap on them.

import NIOConcurrencyHelpers
import NIOCore

/// The open connections of one server: the cap, and the means to close them all.
///
/// Admission is atomic with the count, so the cap holds however many connections arrive at once. A
/// connection over the cap is refused by being closed at once, with nothing written: a refusal that wrote a
/// response would cost the server work in exactly the moment it has none to spare.
///
/// Draining and waiting for connections to end are NIOExtras' `ServerQuiescingHelper`'s job, not this
/// type's; this one exists because a cap needs a count and the end of a grace period needs the channels.
final class ConnectionRegistry: Sendable {
    private struct State {
        var channels: [ObjectIdentifier: any Channel] = [:]
    }

    private let maximum: Int
    private let state = NIOLockedValueBox(State())

    init(maximum: Int) {
        self.maximum = maximum
    }

    /// Records `channel` if there is room.
    func admit(_ channel: any Channel) -> Bool {
        state.withLockedValue { state in
            guard state.channels.count < maximum else { return false }
            state.channels[ObjectIdentifier(channel)] = channel
            return true
        }
    }

    /// Forgets `channel`.
    func remove(_ channel: any Channel) {
        state.withLockedValue { _ = $0.channels.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    /// How many connections are open.
    var count: Int { state.withLockedValue { $0.channels.count } }

    /// Closes every open connection now.
    func closeAll() {
        let open = state.withLockedValue { Array($0.channels.values) }
        for channel in open { channel.close(promise: nil) }
    }
}
