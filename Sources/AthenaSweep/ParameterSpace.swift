import Foundation

// MARK: - ParameterSet

/// A single point in parameter space — one concrete combination of axis
/// values that will be passed to a `StrategyFactory` to build a strategy.
///
/// Values are stored as `Sendable` existentials. Strategies retrieve them
/// by axis name with the typed accessors below, e.g.
/// `params.int("fastPeriod")`.
public struct ParameterSet: Sendable, Hashable, CustomStringConvertible {
    public let values: [String: AnySendableValue]

    public init(_ values: [String: AnySendableValue]) {
        self.values = values
    }

    public func int(_ key: String) -> Int? { values[key]?.asInt }
    public func double(_ key: String) -> Double? { values[key]?.asDouble }
    public func decimal(_ key: String) -> Decimal? { values[key]?.asDecimal }
    public func string(_ key: String) -> String? { values[key]?.asString }
    public func bool(_ key: String) -> Bool? { values[key]?.asBool }

    public var description: String {
        let parts = values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        return "{" + parts.joined(separator: ", ") + "}"
    }
}

/// Type-erased Sendable value for parameter axis values. Wraps the
/// supported primitive types so a `ParameterSet` can carry mixed-type
/// values without leaking generics into the API.
public struct AnySendableValue: Sendable, Hashable, CustomStringConvertible {
    public enum Storage: Sendable, Hashable {
        case int(Int)
        case double(Double)
        case decimal(Decimal)
        case string(String)
        case bool(Bool)
    }
    public let storage: Storage

    public init(_ v: Int) { storage = .int(v) }
    public init(_ v: Double) { storage = .double(v) }
    public init(_ v: Decimal) { storage = .decimal(v) }
    public init(_ v: String) { storage = .string(v) }
    public init(_ v: Bool) { storage = .bool(v) }

    public var asInt: Int? {
        if case .int(let v) = storage { return v }
        return nil
    }
    public var asDouble: Double? {
        switch storage {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    public var asDecimal: Decimal? {
        switch storage {
        case .decimal(let v): return v
        case .int(let v): return Decimal(v)
        case .double(let v): return Decimal(v)
        default: return nil
        }
    }
    public var asString: String? {
        if case .string(let v) = storage { return v }
        return nil
    }
    public var asBool: Bool? {
        if case .bool(let v) = storage { return v }
        return nil
    }

    public var description: String {
        switch storage {
        case .int(let v): return "\(v)"
        case .double(let v): return "\(v)"
        case .decimal(let v): return "\(v)"
        case .string(let v): return "\"\(v)\""
        case .bool(let v): return "\(v)"
        }
    }
}

// MARK: - ParameterAxis

/// One axis of a parameter sweep: an axis name plus the discrete values
/// to try along it.
public struct ParameterAxis: Sendable, Hashable {
    public let name: String
    public let values: [AnySendableValue]

    public init(name: String, values: [AnySendableValue]) {
        self.name = name
        self.values = values
    }

    public static func ints(_ name: String, _ values: [Int]) -> ParameterAxis {
        ParameterAxis(name: name, values: values.map(AnySendableValue.init))
    }
    public static func doubles(_ name: String, _ values: [Double]) -> ParameterAxis {
        ParameterAxis(name: name, values: values.map(AnySendableValue.init))
    }
    public static func decimals(_ name: String, _ values: [Decimal]) -> ParameterAxis {
        ParameterAxis(name: name, values: values.map(AnySendableValue.init))
    }
    public static func strings(_ name: String, _ values: [String]) -> ParameterAxis {
        ParameterAxis(name: name, values: values.map(AnySendableValue.init))
    }
    public static func bools(_ name: String, _ values: [Bool]) -> ParameterAxis {
        ParameterAxis(name: name, values: values.map(AnySendableValue.init))
    }
}

// MARK: - ParameterSpace

/// A `ParameterSpace` enumerates the `ParameterSet`s a sweep should run.
public struct ParameterSpace: Sendable {
    public let sets: [ParameterSet]

    public init(_ sets: [ParameterSet]) { self.sets = sets }

    /// Cartesian product of all axes. Empty axes produce an empty space.
    public static func grid(_ axes: [ParameterAxis]) -> ParameterSpace {
        guard !axes.isEmpty, axes.allSatisfy({ !$0.values.isEmpty }) else {
            return ParameterSpace([])
        }
        var combos: [[String: AnySendableValue]] = [[:]]
        for axis in axes {
            var next: [[String: AnySendableValue]] = []
            next.reserveCapacity(combos.count * axis.values.count)
            for c in combos {
                for v in axis.values {
                    var n = c
                    n[axis.name] = v
                    next.append(n)
                }
            }
            combos = next
        }
        return ParameterSpace(combos.map { ParameterSet($0) })
    }

    /// Random sampling — picks `count` `ParameterSet`s by independently
    /// sampling each axis (uniform over the axis's value list). Seeded
    /// for determinism. Sampling is *with replacement* across axes —
    /// duplicate `ParameterSet`s may occur on small spaces.
    public static func random(
        axes: [ParameterAxis],
        count: Int,
        seed: UInt64
    ) -> ParameterSpace {
        guard count > 0, !axes.isEmpty, axes.allSatisfy({ !$0.values.isEmpty }) else {
            return ParameterSpace([])
        }
        var rng = Xoshiro256StarStar(seed: seed)
        var sets: [ParameterSet] = []
        sets.reserveCapacity(count)
        for _ in 0..<count {
            var dict: [String: AnySendableValue] = [:]
            for axis in axes {
                let idx = Int(rng.next() % UInt64(axis.values.count))
                dict[axis.name] = axis.values[idx]
            }
            sets.append(ParameterSet(dict))
        }
        return ParameterSpace(sets)
    }
}

// MARK: - Xoshiro256** RNG

/// Tiny seeded RNG for deterministic random sweeps. xoshiro256\*\* —
/// passes BigCrush, 256-bit state, fast.
public struct Xoshiro256StarStar: RandomNumberGenerator, Sendable {
    private var state: (UInt64, UInt64, UInt64, UInt64)

    public init(seed: UInt64) {
        // SplitMix64 to expand a single 64-bit seed into 256 bits of state.
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        func mix(_ x: UInt64) -> UInt64 {
            var y = x
            y = (y ^ (y >> 30)) &* 0xBF58_476D_1CE4_E5B9
            y = (y ^ (y >> 27)) &* 0x94D0_49BB_1331_11EB
            return y ^ (y >> 31)
        }
        let s0 = mix(z); z &+= 0x9E37_79B9_7F4A_7C15
        let s1 = mix(z); z &+= 0x9E37_79B9_7F4A_7C15
        let s2 = mix(z); z &+= 0x9E37_79B9_7F4A_7C15
        let s3 = mix(z)
        // Avoid the all-zero state.
        state = (s0 == 0 ? 1 : s0, s1, s2, s3)
    }

    public mutating func next() -> UInt64 {
        let result = rotl(state.1 &* 5, 7) &* 9
        let t = state.1 &<< 17
        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3
        state.2 ^= t
        state.3 = rotl(state.3, 45)
        return result
    }

    private func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
        (x &<< k) | (x &>> (64 - k))
    }
}
