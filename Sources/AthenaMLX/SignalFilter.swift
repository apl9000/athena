import Foundation

// MARK: - SignalFilter

/// A post-processor applied to a `VectorizableStrategy`'s boolean signal array
/// before it reaches `VectorizedFillSimulator`.
///
/// Filters can be chained by composing them sequentially. Each filter receives
/// the output of the previous one.
///
/// ## Invariant
/// Every implementation must return an array whose `count` equals `signals.count`.
/// Violating the length contract will cause a runtime trap in `MLXBacktestRunner`.
public protocol SignalFilter: Sendable {
    /// Apply the filter to a raw signal array.
    ///
    /// - Parameter signals: The raw `Bool` signals produced by
    ///   `VectorizableStrategy.signals(for:)`.
    /// - Returns: A filtered array of the same length as `signals`.
    func filter(_ signals: [Bool]) -> [Bool]
}

// MARK: - DebounceFilter

/// Suppresses rapid signal flips within `minBars` of the previous flip.
///
/// Useful for noisy strategies that flip in and out of a position on consecutive
/// bars — debouncing reduces churn and can improve net-of-commission results.
public struct DebounceFilter: SignalFilter {
    /// The minimum number of bars that must elapse between two consecutive flips.
    public let minBars: Int

    public init(minBars: Int) {
        self.minBars = minBars
    }

    public func filter(_ signals: [Bool]) -> [Bool] {
        guard !signals.isEmpty else { return [] }
        var result = signals
        var lastFlipIndex = -minBars
        for i in 1..<result.count {
            if result[i] != result[i - 1] {
                if i - lastFlipIndex < minBars {
                    result[i] = result[i - 1]
                } else {
                    lastFlipIndex = i
                }
            }
        }
        return result
    }
}
