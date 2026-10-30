// HeadGuard.swift
// SwiftHTTPServiceNIO
//
// The first handler in the pipeline: it sees raw bytes, before any parser has buffered them.

import NIOCore
import SwiftHTTPService

/// What the guard tells the connection handler, as inbound user events.
enum GuardEvent: Sendable, Equatable {
    /// The request line and headers did not finish within `headerReadTimeout` of their first byte.
    case headerTimeout
    /// The request line and headers passed `maximumHeaderBytes` without ending.
    case headTooLarge
    /// A keep-alive connection waited `idleTimeout` for its next request.
    case idleTimeout
    /// A new connection sent nothing in `idleTimeout`. It is a request that is late, not a connection that is idle,
    /// so it is answered (408) where an idle keep-alive connection is closed silently.
    case silentTimeout
    /// The request line names an HTTP major version other than 1.
    case unsupportedVersion
}

/// What the connection handler tells the guard, as outbound user events.
enum GuardSignal: Sendable, Equatable {
    /// A request has been fully read: the next bytes begin a new head.
    case requestFinished
    /// The response has been written and the connection stays open: start waiting for the next request.
    case responseFinished
    /// Stop counting, stop timing and drop everything that arrives (the connection is going away).
    case discard
}

/// Counts the bytes of each request line and header block *as they arrive*, because the HTTP parser does
/// not: it bounds header fields but not the request line, and it keeps nothing a limit could be applied to.
/// A request line that never ends is refused here, once it passes the limit, without waiting for its end.
///
/// It also owns the two timers that depend on raw bytes arriving:
///
/// - the **header deadline**, started at a request's first byte and cancelled when the blank line ends the
///   head. It is a deadline on the whole head, not a gap between bytes, so dripping one byte a second does
///   not extend it (slowloris);
/// - the **idle timer**, armed when a connection opens and after each response, cancelled by the next byte.
///
/// Bytes after a head's blank line (a body, or a pipelined request) are not counted here: the body has its
/// own limit in the connection handler, and the handler refuses pipelining.
// Justification: a channel handler is confined to its event loop and `@unchecked Sendable` only lets NIOLoopBound hold it.
final class HeadGuard: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum Phase {
        /// Reading a head. `bytes` is how many have arrived; `matched` is how much of CRLFCRLF has just been seen.
        case head(bytes: Int, matched: Int)
        /// The head is complete; a body may follow, until the connection handler says the request is finished.
        case body
        /// The connection is going away: nothing more is counted or passed on.
        case discarding
    }

    private let limits: Limits
    private var phase: Phase = .head(bytes: 0, matched: 0)
    private var headerTimer: Scheduled<Void>?
    private var idleTimer: Scheduled<Void>?
    /// Whether any byte has arrived on this connection. Until one has, a quiet connection is a late first request.
    private var hasReceivedBytes = false
    /// The last bytes of the request line in progress (enough to hold ` HTTP/d.d`), until its line feed.
    private var lineTail: [UInt8] = []
    private var lineEnded = false

    init(limits: Limits) {
        self.limits = limits
    }

    // MARK: Lifecycle

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { armIdleTimer(context: context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        armIdleTimer(context: context)
        context.fireChannelActive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        cancelTimers()
    }

    func channelInactive(context: ChannelHandlerContext) {
        cancelTimers()
        context.fireChannelInactive()
    }

    // MARK: Inbound

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        switch phase {
        case .discarding:
            return
        case .body:
            context.fireChannelRead(data)
        case .head(var bytes, var matched):
            if bytes == 0 {
                hasReceivedBytes = true
                idleTimer?.cancel()
                idleTimer = nil
                armHeaderTimer(context: context)
            }
            var found = false
            for byte in buffer.readableBytesView {
                if bytes == limits.maximumHeaderBytes {
                    phase = .discarding
                    cancelTimers()
                    context.fireUserInboundEventTriggered(GuardEvent.headTooLarge)
                    return
                }
                bytes += 1
                if !lineEnded, Self.endsLine(byte, tail: &lineTail) {
                    lineEnded = true
                    if Self.hasUnsupportedMajor(requestLine: lineTail) {
                        phase = .discarding
                        cancelTimers()
                        context.fireUserInboundEventTriggered(GuardEvent.unsupportedVersion)
                        return
                    }
                }
                matched = Self.advance(matched, byte)
                if matched == 4 {
                    found = true
                    break
                }
            }
            if found {
                headerTimer?.cancel()
                headerTimer = nil
                phase = .body
            } else {
                phase = .head(bytes: bytes, matched: matched)
            }
            context.fireChannelRead(data)
        }
    }

    // MARK: Signals from the connection handler

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        guard let signal = event as? GuardSignal else {
            context.triggerUserOutboundEvent(event, promise: promise)
            return
        }
        switch signal {
        case .requestFinished:
            if case .discarding = phase {} else { phase = .head(bytes: 0, matched: 0) }
            lineTail.removeAll(keepingCapacity: true)
            lineEnded = false
        case .responseFinished:
            if case .head(let bytes, _) = phase, bytes == 0, headerTimer == nil { armIdleTimer(context: context) }
        case .discard:
            phase = .discarding
            cancelTimers()
        }
        promise?.succeed(())
    }

    // MARK: Pieces

    /// Advances the match of `\r\n\r\n` by one byte: the next state is how many of its characters have
    /// just been seen in a row.
    static func advance(_ matched: Int, _ byte: UInt8) -> Int {
        let pattern: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        if matched < 4, byte == pattern[matched] { return matched + 1 }
        return byte == 0x0D ? 1 : 0
    }

    /// Feeds one byte of a request line; true at its line feed. Only the last ten bytes are kept, which is all that
    /// ` HTTP/d.d` and a carriage return need.
    static func endsLine(_ byte: UInt8, tail: inout [UInt8]) -> Bool {
        if byte == 0x0A { return true }
        tail.append(byte)
        if tail.count > 10 { tail.removeFirst(tail.count - 10) }
        return false
    }

    /// Whether a request line ends in ` HTTP/d.d` with a major version digit that is not 1. Anything else (a
    /// version that is not of that shape, or a 1.x) is the parser's to judge.
    static func hasUnsupportedMajor(requestLine tail: [UInt8]) -> Bool {
        var line = tail
        if line.last == 0x0D { line.removeLast() }
        guard line.count >= 9 else { return false }
        let version = Array(line.suffix(8))
        let prefix = Array("HTTP/".utf8)
        guard line[line.count - 9] == 0x20,
              Array(version.prefix(5)) == prefix,
              version[6] == 0x2E,
              (0x30...0x39).contains(version[5]), (0x30...0x39).contains(version[7])
        else { return false }
        return version[5] != 0x31
    }

    private func armHeaderTimer(context: ChannelHandlerContext) {
        headerTimer?.cancel()
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        headerTimer = context.eventLoop.scheduleTask(in: limits.headerReadTimeout.timeAmount) { [weak self] in
            guard let self else { return }
            self.headerTimer = nil
            self.phase = .discarding
            loopContext.value.fireUserInboundEventTriggered(GuardEvent.headerTimeout)
        }
    }

    private func armIdleTimer(context: ChannelHandlerContext) {
        idleTimer?.cancel()
        let loopContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        idleTimer = context.eventLoop.scheduleTask(in: limits.idleTimeout.timeAmount) { [weak self] in
            guard let self else { return }
            self.idleTimer = nil
            loopContext.value.fireUserInboundEventTriggered(self.hasReceivedBytes ? GuardEvent.idleTimeout : GuardEvent.silentTimeout)
        }
    }

    private func cancelTimers() {
        headerTimer?.cancel()
        headerTimer = nil
        idleTimer?.cancel()
        idleTimer = nil
    }
}

extension Duration {
    /// The same span as a `TimeAmount`, rounded to the nearest nanosecond.
    var timeAmount: TimeAmount {
        let parts = components
        let nanoseconds = parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
        return .nanoseconds(nanoseconds)
    }
}
