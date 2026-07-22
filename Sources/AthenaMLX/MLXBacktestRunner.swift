import AthenaCore
import AthenaBacktest
import AthenaSweep

// MARK: - MLXBacktestRunner

/// A ``BacktestRunner`` with an MLX-backed fast path for vectorizable
/// strategies on Apple Silicon (macOS / iOS).
///
/// ## Fast-path eligibility
/// Both conditions must be met for a cell to take the MLX fast path:
/// 1. The strategy conforms to ``VectorizableStrategy``.
/// 2. The ``BacktestConfig`` uses ``NoTaxes`` (tax-regime vectorization
///    is out of scope for v0.5).
///
/// ## Fallback behaviour
/// When either condition is not met, the runner transparently routes
/// the cell to ``EventDrivenRunner``. Callers never need to detect or
/// handle the dispatch themselves — the result shape is always the
/// same ``BacktestResult`` regardless of which path ran.
///
/// Two explicit fallback triggers:
/// - **Non-`VectorizableStrategy`**: any strategy that does not implement
///   ``VectorizableStrategy/signals(for:)`` is routed through
///   ``EventDrivenRunner`` on a per-cell basis.
/// - **Non-`NoTaxes` tax regime**: any ``BacktestConfig`` whose
///   `taxRegime` is not ``NoTaxes`` (e.g. ``USWashSale``,
///   ``CanadianACB``) always falls back to ``EventDrivenRunner``.
///
/// ## v0.5 slice 2 (this file — fallback paths)
/// Slice 1 established the ``BacktestRunner`` seam. Slice 2 adds the
/// explicit dispatch decision. The MLX tensor fast path will replace the
/// `#if canImport(MLX)` placeholder in a later slice once `mlx-swift` is
/// added as a conditional macOS / iOS dependency.
///
/// ## Usage
/// ```swift
/// let sweep = Sweep(
///     factory: factory,
///     runner: MLXBacktestRunner(),  // ← only new line vs v0.4
///     bars: bars,
///     config: config,
///     space: space
/// )
/// ```
public struct MLXBacktestRunner: BacktestRunner {

    public init() {}

    // MARK: BacktestRunner

    /// Run one backtest cell, routing to the MLX fast path when eligible
    /// or falling back to ``EventDrivenRunner`` otherwise.
    ///
    /// **Dispatch logic:**
    /// - If `strategy` does not conform to ``VectorizableStrategy`` **or**
    ///   `config.taxRegime` is not ``NoTaxes``, the call is forwarded to
    ///   ``EventDrivenRunner`` and the result is returned unchanged.
    /// - If both conditions are met, the cell is eligible for the MLX
    ///   tensor fast path. In the current slice that path still delegates
    ///   to ``EventDrivenRunner``; real tensor dispatch is gated on
    ///   `#if canImport(MLX)` and lands in a later slice.
    ///
    /// Result shape and numeric values are identical across all paths in
    /// the current slice so that switching runners is a zero-risk change.
    public func run(
        strategy: any Strategy,
        bars: [Bar],
        config: BacktestConfig
    ) async throws -> BacktestResult {
        // Determine fast-path eligibility.
        // Both conditions must hold; failing either triggers the explicit fallback.
        let isVectorizable = strategy is any VectorizableStrategy
        let isNoTaxes = config.taxRegime is NoTaxes

        guard isVectorizable && isNoTaxes else {
            // Explicit fallback path:
            // • Non-VectorizableStrategy: strategy lacks signals(for:).
            // • Non-NoTaxes regime: tax-regime vectorization is out of v0.5 scope.
            // Both cases produce results that are numerically identical to a
            // direct EventDrivenRunner call — the fallback is transparent.
            return try await EventDrivenRunner().run(
                strategy: strategy,
                bars: bars,
                config: config
            )
        }

        // Fast path: VectorizableStrategy + NoTaxes.
        // Real MLX tensor dispatch is gated here; until mlx-swift is added
        // as a conditional dependency this path also delegates to
        // EventDrivenRunner, keeping non-Apple-Silicon builds green.
        // Both branches are intentionally identical at this slice — the
        // #if canImport(MLX) block marks exactly where tensor dispatch lands.
        #if canImport(MLX)
        // TODO: Replace with MLX tensor dispatch in the vectorized-fills slice.
        return try await EventDrivenRunner().run(
            strategy: strategy,
            bars: bars,
            config: config
        )
        #else
        return try await EventDrivenRunner().run(
            strategy: strategy,
            bars: bars,
            config: config
        )
        #endif
    }
}
