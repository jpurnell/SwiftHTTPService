import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SwiftHTTPService
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import SwiftHTTPServiceNIO

/// What this process holds: resident memory and open descriptors, read from the operating system.
///
/// The server runs in this process (the soak drives it from the same test process), so these are the server's own numbers
/// plus the clients', and the clients are closed at every drain point: a leak in either shows as growth.
enum ProcessMeter {
    /// Resident set size in bytes (on macOS the peak since the process began; on Linux the current size), or nil if the
    /// platform's source cannot be read.
    static func residentBytes() -> Int? {
        #if canImport(Darwin)
        // The peak resident size (bytes on Darwin). task_info and proc_pid_rusage give the current size but need typed
        // pointers into C structures, and a child `ps` needs a spawn; the quality gate refuses both. The peak is the
        // conservative figure for a leak: a leak raises it, and it never falls, so growth after warm-up is the new peak.
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Int(usage.ru_maxrss)
        #else
        // /proc/self/statm: size resident shared text lib data dt, in pages.
        guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return nil }
        let fields = text.split(separator: " ")
        guard fields.count > 1, let pages = Int(fields[1]) else { return nil }
        return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
        #endif
    }

    /// The number of open file descriptors, counting the one used to list them.
    static func openDescriptors() -> Int? {
        #if canImport(Darwin)
        let directory = "/dev/fd"
        #else
        let directory = "/proc/self/fd"
        #endif
        return (try? FileManager.default.contentsOfDirectory(atPath: directory))?.count
    }
}

/// A long run of mixed traffic against one plaintext and one TLS server, to see whether memory or descriptors grow.
///
/// Skipped unless `SOAK_SECONDS` is set (`Scripts/soak.sh 60` sets it). The run is a series of cycles: workers open,
/// abuse and close connections for `loadSeconds`, then stop; after `drainSeconds`, longer than every server timeout, nothing
/// should be left open, and the process's resident memory and descriptor count are sampled. Sampling at a quiet point
/// is what separates a leak from the traffic that is merely in flight.
@Suite("Soak", .serialized)
struct SoakTests {

    static let seconds: Int? = ProcessInfo.processInfo.environment["SOAK_SECONDS"].flatMap { Int($0) }
    static let enabled = (seconds ?? 0) > 0

    /// Seconds of traffic, and of quiet, in one cycle. The server's longest timer is `idleTimeout`, 0.5 s.
    static let loadSeconds = 3.0
    static let drainSeconds = 1.5
    /// The first cycles are warm-up: allocators, caches, the TLS context and the event loops reach their working size.
    static let warmupCycles = 3

    /// Allowed growth of the resident size over the baseline (the sample at the end of warm-up), as a fraction: 25%.
    /// Measured on the development machine, three 60 s runs of about 10,000 sessions each (12 cycles): the worst growth
    /// after warm-up, of the peak resident size, was +10.2% in one run and 0.0% in another (the first run, measured with a
    /// different meter, was within +/-5%). 25% is about two and a half times the worst observed. The longer the run, the
    /// smaller a leak this can see: 25% of 100 MB is 25 MB, so a minute of traffic shows a leak above about 2.5 KB a session.
    static let residentGrowthLimit = 0.25
    /// Allowed growth of the open descriptor count over the baseline. Measured: 27 at every sample of a 60 s run, growth 0.
    /// A leak of one descriptor per session would be thousands in a minute, so 8 (the few that a lazily created resource
    /// might hold) is far below any leak and above nothing observed.
    static let descriptorGrowthLimit = 8

    static let seed: UInt64 = 0x5EED_0007

    struct Sample: Sendable {
        var cycle: Int
        var resident: Int
        var descriptors: Int
    }

    private func handler() -> Handler {
        { request in
            switch request.path {
            case "/stream":
                return .streaming(status: .ok) { writer in
                    for _ in 0..<200 { try await writer.write(Data("tick\n".utf8)); try await Task.sleep(for: .milliseconds(5)) }
                }
            case "/big":
                return .streaming(status: .ok) { writer in
                    let chunk = Data(repeating: 0x61, count: 1 << 20)
                    for _ in 0..<64 { try await writer.write(chunk) }
                }
            default:
                return Response(status: .ok, body: Data("ok".utf8))
            }
        }
    }

    private func limits() -> Limits {
        var limits = Limits()
        limits.headerReadTimeout = .milliseconds(300)
        limits.bodyReadTimeout = .milliseconds(300)
        limits.idleTimeout = .milliseconds(500)
        limits.streamWriteTimeout = .milliseconds(300)
        limits.shutdownGrace = .seconds(2)
        return limits
    }

    /// One unit of traffic, chosen by the worker's seeded generator.
    private static func oneSession(
        _ rng: inout SplitMix64, counter: NIOLockedValueBox<Int>, plain: BoundAddress, secure: BoundAddress, tls: TestTLS, group: MultiThreadedEventLoopGroup
    ) async {
        let choice = rng.int(0...9)
        counter.withLockedValue { $0 += 1 }
        do {
            switch choice {
            case 0, 1:                                                          // ordinary keep-alive traffic
                let client = try await RawClient.connect(to: plain, group: group)
                for _ in 0..<3 {
                    try await client.send("GET /x HTTP/1.1\r\nHost: h\r\n\r\n")
                    _ = try await client.response(timeout: .seconds(2))
                    client.collector.received.withLockedValue { $0.removeAll() }
                }
                await client.close()
            case 2:                                                             // a head dribbled, then abandoned
                let client = try await RawClient.connect(to: plain, group: group)
                try await client.send("GET /x HT")
                try await Task.sleep(for: .milliseconds(rng.int(0...80)))
                await client.close()
            case 3:                                                             // closed in the middle of a body
                let client = try await RawClient.connect(to: plain, group: group)
                try await client.send("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 100\r\n\r\nabcdefghij")
                try await Task.sleep(for: .milliseconds(rng.int(0...50)))
                await client.close()
            case 4:                                                             // closed in the middle of a streaming response
                let client = try await RawClient.connect(to: plain, group: group)
                try await client.send("GET /stream HTTP/1.1\r\nHost: h\r\n\r\n")
                _ = try await client.wait(timeout: .seconds(2)) { $0.received.count > 20 }
                await client.close()
            case 5:                                                             // malformed bytes
                let client = try await RawClient.connect(to: plain, group: group)
                let garbage = (0..<rng.int(1...300)).map { _ in UInt8.random(in: 0...255, using: &rng) }
                try await client.channel.writeAndFlush(ByteBuffer(bytes: garbage)).get()
                _ = try await client.waitUntilClosed(timeout: .milliseconds(rng.int(20...300)))
                await client.close()
            case 6:                                                             // the client shuts its sending side while the response is streaming (a half-close)
                let client = try await RawClient.connect(to: plain, group: group)
                try await client.send("GET /stream HTTP/1.1\r\nHost: h\r\n\r\n")
                try await Task.sleep(for: .milliseconds(rng.int(0...30)))
                try? await client.channel.close(mode: .output).get()
                await client.close()
            case 7:                                                             // a reader that stalls on a large response
                let client = try await RawClient.connect(to: plain, group: group)
                try await client.channel.setOption(ChannelOptions.autoRead, value: false).get()
                try await client.send("GET /big HTTP/1.1\r\nHost: h\r\n\r\n")
                try await Task.sleep(for: .milliseconds(rng.int(50...400)))
                await client.close()
            case 8:                                                             // HTTP/2: a request, a stream abandoned, a connection closed
                let client = try await H2Client.connect(to: secure, group: group, tls: try tls.clientContext(applicationProtocols: ["h2"]))
                _ = try await client.request("GET", "/x")
                let stream = try await client.open("GET", "/stream")
                _ = try await stream.wait(timeout: .seconds(2)) { $0.body.count > 10 }
                await stream.reset()
                await client.close()
            default:                                                            // a client that connects and waits for the server's idle timeout
                let client = try await RawClient.connect(to: plain, group: group)
                _ = try await client.waitUntilClosed(timeout: .seconds(2))
                await client.close()
            }
        } catch {
            // A refused or reset connection is part of the traffic, not a failure of the soak.
        }
    }

    @Test("Memory and descriptors do not grow over a long run of opened, abused and closed connections",
          .enabled(if: SoakTests.enabled, "set SOAK_SECONDS to run the soak (Scripts/soak.sh does)"))
    func soak() async throws {
        let total = Double(Self.seconds ?? 0)
        let material = try TestTLS()
        defer { material.cleanUp() }
        let plain = try await startServer(limits: limits(), handler: handler())
        let secure = try await startServer(limits: limits(), tls: material.files, handler: handler())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)

        var samples: [Sample] = []
        let sessions = NIOLockedValueBox(0)
        let began = ContinuousClock.now
        var cycle = 0
        while (ContinuousClock.now - began).seconds < total {
            let thisCycle = cycle
            let until = ContinuousClock.now + .milliseconds(Int(Self.loadSeconds * 1000))
            await withTaskGroup(of: Void.self) { workers in
                for worker in 0..<24 {
                    workers.addTask {
                        var rng = SplitMix64(seed: Self.seed &+ UInt64(thisCycle * 100 + worker))
                        while ContinuousClock.now < until {
                            await Self.oneSession(&rng, counter: sessions, plain: plain.address, secure: secure.address, tls: material, group: group)
                        }
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(Int(Self.drainSeconds * 1000)))
            let resident = try #require(ProcessMeter.residentBytes(), "cannot read the process's resident size on this platform")
            let descriptors = try #require(ProcessMeter.openDescriptors(), "cannot count open descriptors on this platform")
            let sample = Sample(cycle: cycle, resident: resident, descriptors: descriptors)
            samples.append(sample)
            recordMeasurement("soak sample", "cycle \(cycle) t=\((ContinuousClock.now - began).seconds.rounded()) s resident=\(resident / 1024) KiB fds=\(descriptors)")
            cycle += 1
        }

        try await group.shutdownGracefully()
        await plain.server.shutdown()
        await secure.server.shutdown()

        #expect(samples.count > Self.warmupCycles, "the run was too short to leave warm-up (\(samples.count) cycles)")
        guard samples.count > Self.warmupCycles else { return }
        let baseline = samples[Self.warmupCycles - 1]
        let after = samples.dropFirst(Self.warmupCycles)
        let worstResident = after.map(\.resident).max() ?? baseline.resident
        let worstDescriptors = after.map(\.descriptors).max() ?? baseline.descriptors
        let residentGrowth = Double(worstResident - baseline.resident) / Double(baseline.resident)
        recordMeasurement("soak result", "sessions=\(sessions.withLockedValue { $0 }) cycles=\(samples.count) baseline resident=\(baseline.resident / 1024) KiB fds=\(baseline.descriptors); worst after warm-up resident=\(worstResident / 1024) KiB (growth \(residentGrowth * 100)%) fds=\(worstDescriptors) (growth \(worstDescriptors - baseline.descriptors)); last resident=\((samples.last?.resident ?? 0) / 1024) KiB")
        #expect(residentGrowth <= Self.residentGrowthLimit, "resident memory grew \(residentGrowth * 100)% after warm-up (limit \(Self.residentGrowthLimit * 100)%)")
        #expect(worstDescriptors - baseline.descriptors <= Self.descriptorGrowthLimit, "open descriptors grew by \(worstDescriptors - baseline.descriptors) after warm-up (limit \(Self.descriptorGrowthLimit))")
    }
}
