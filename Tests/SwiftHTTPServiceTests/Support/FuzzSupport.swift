import Foundation

/// SplitMix64 (Steele, Lea and Flood, 2014): a small, seeded, deterministic generator. The fuzz tests never use an
/// unseeded source, so a failing case is reproduced by its seed and index.
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

/// Writes one measurement line to standard error (`grep RIG-MEASURE`).
func recordMeasurement(_ name: String, _ value: String) {
    FileHandle.standardError.write(Data("RIG-MEASURE \(name): \(value)\n".utf8))
}

/// `value` in base 16, upper case, left-padded with zeros to `width` digits.
func paddedHex(_ value: UInt64, width: Int, uppercase: Bool = true) -> String {
    let digits = String(value, radix: 16, uppercase: uppercase)
    return String(repeating: "0", count: max(width - digits.count, 0)) + digits
}
