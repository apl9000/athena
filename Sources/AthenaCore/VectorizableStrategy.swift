import Foundation

// MARK: - VectorizableStrategy

/// An opt-in protocol for strategies that can express their signal logic
/// as a single vectorized pass over a bar array.
///
/// Strategies that conform to `VectorizableStrategy` are eligible for the
/// `MLXBacktestRunner` fast path in `AthenaMLX`. Non-conforming strategies
/// are silently routed to `EventDrivenRunner` on a per-cell basis — callers
/// never need to handle the dispatch themselves.
///
/// ## v0.5 scope
/// Long-only / flat positions only. Short positions, sized positions,
/// leverage, and multi-symbol signal dependencies are out of scope.
///
/// ## Implementation contract
/// - ``signals(for:)`` must return an array of the **same length** as `bars`.
/// - Each element is `true` (long — fully in) or `false` (flat — fully out).
/// - A transition from `false → true` triggers a **buy at the next bar's open**.
/// - A transition from `true → false` triggers a **sell at the next bar's open**.
/// - The ``Strategy`` methods (``onStart``, ``onBar``, ``onFinish``) remain
///   fully available for event-driven use; `VectorizableStrategy` only adds
///   the `signals(for:)` method.
///
/// ## Example
/// ```swift
/// struct SMACrossover: Strategy, VectorizableStrategy {
///     let fast: Int
///     let slow: Int
///
///     func onBar(_ bar: Bar, context: StrategyContext) async throws { ... }
///
///     func signals(for bars: [Bar]) -> [Bool] {
///         // compute SMA vectors and return long/flat signal per bar
///     }
/// }
/// ```
public protocol VectorizableStrategy: Strategy {
    /// Compute a position signal for every bar in `bars` in a single pass.
    ///
    /// - Parameter bars: The full bar sequence for the backtest. The array
    ///   is the same `bars` that was passed to the ``Sweep``.
    /// - Returns: A `Bool` array whose length equals `bars.count`. `true`
    ///   means "long"; `false` means "flat". A change between adjacent
    ///   elements triggers a fill at the **next** bar's open.
    func signals(for bars: [Bar]) -> [Bool]
}
