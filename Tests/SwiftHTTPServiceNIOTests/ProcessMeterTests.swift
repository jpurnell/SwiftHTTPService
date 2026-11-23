import Foundation
import Testing
@testable import SwiftHTTPServiceNIO

/// The soak's meter must tell a leak from an allocator that keeps what was freed. Live heap is what the process still holds;
/// retained is what the allocator holds beyond that. The expectations are what holding and freeing a known amount does, not
/// what the meter happened to return.
@Suite("The soak's process meter", .serialized)
struct ProcessMeterTests {

    /// Allocates `count` blocks of `size` bytes that the optimiser cannot remove.
    private static func hold(blocks count: Int, size: Int) -> [[UInt8]] {
        (0..<count).map { index in [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: size) }
    }

    @Test("Live heap rises by what is held and falls by about that much when it is released",
          .enabled(if: ProcessMeter.hasAllocatorCount, "only an allocator count falls when memory is freed"))
    func liveTracksHolding() throws {
        // Other suites allocate and free in this process while this runs, so the expectations compare readings taken
        // around the hold with the 20 MB held, and leave room for what runs beside it.
        let before = try #require(ProcessMeter.heap(), "this platform cannot report heap use")
        var held: [[UInt8]]? = Self.hold(blocks: 200, size: 100_000)                // 20 MB
        let during = try #require(ProcessMeter.heap())
        #expect(during.live - before.live >= 15_000_000, "holding 20 MB raised live heap by \(during.live - before.live)")
        #expect(held?.count == 200)
        held = nil
        let after = try #require(ProcessMeter.heap())
        #expect(during.live - after.live >= 15_000_000, "releasing 20 MB lowered live heap by \(during.live - after.live)")
    }

    @Test("Freed memory the allocator keeps shows as retained, not as live",
          .enabled(if: ProcessMeter.hasAllocatorCount, "only an allocator count separates live from retained"))
    func retainedAfterFree() throws {
        var held: [[UInt8]]? = Self.hold(blocks: 200, size: 100_000)
        let during = try #require(ProcessMeter.heap())
        #expect(held?.count == 200)
        held = nil
        let after = try #require(ProcessMeter.heap())
        // What was live is now free; some of it may go back to the system, but live + retained cannot fall below
        // what the process still holds, and the drop in live must reappear as free memory or as returned pages.
        #expect(after.live < during.live)
        #expect(after.retained > 0)
    }
}
