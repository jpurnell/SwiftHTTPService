import Foundation

/// Writes one measurement line to standard error, so a run's observed numbers can be read from its output
/// (`grep RIG-MEASURE`). Tolerances in the rig come from these numbers, not from guesses.
func recordMeasurement(_ name: String, _ value: String) {
    FileHandle.standardError.write(Data("RIG-MEASURE \(name): \(value)\n".utf8))
}

extension Duration {
    /// The duration in seconds as a double, for comparisons and for printing.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// SplitMix64 (Steele, Lea and Flood, 2014): a small, seeded, deterministic generator. The rig never uses `Int.random`.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SplitMix64 {
    /// A uniformly chosen element of a non-empty array.
    mutating func pick<T>(_ items: [T]) -> T {
        items[Int.random(in: 0..<items.count, using: &self)]
    }

    /// An integer in `range`.
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    /// True with probability `percent` out of 100.
    mutating func chance(_ percent: Int) -> Bool {
        Int.random(in: 0..<100, using: &self) < percent
    }
}

/// `value` in base 16, upper case, left-padded with zeros to `width` digits.
func paddedHex(_ value: UInt64, width: Int, uppercase: Bool = true) -> String {
    let digits = String(value, radix: 16, uppercase: uppercase)
    return String(repeating: "0", count: max(width - digits.count, 0)) + digits
}
