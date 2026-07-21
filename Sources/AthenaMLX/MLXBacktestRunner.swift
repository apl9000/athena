import AthenaCore
import AthenaBacktest
import AthenaSweep

// MARK: - MLXBacktestRunner

/// A ``BacktestRunner`` with an MLX-backed fast path for vectorizable
/// strategies on Apple Silicon (macOS / iOS).
///
/// **Fast-path eligibility (later v0.5 slices):**
/// - The strategy must conform to ``VectorizableStrategy``.
/// - The ``BacktestConfig`` must use ``NoTaxes`` (tax-regime vectorization
///   is out of scope for v0.5).
///
/// When neither condition is met the runner transparently falls back to
/// ``EventDrivenRunner`` per cell, so callers never need to handle the
/// dispatch themselves.
///
/// **v0.5 slice 1 (this file):** the seam is in place — `MLXBacktestRunner`
/// fully conforms to ``BacktestRunner`` — but the tensor dispatch is
/// delegated to ``EventDrivenRunner`` until later slices add real MLX work.
/// Switching to `MLXBacktestRunner` today is safe and produces identical
/// results to the event-driven path.
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

    /// Run one backtest cell.
    ///
    /// **Slice 1 behaviour:** always delegates to ``EventDrivenRunner``.
    /// Later slices will inspect `strategy` for ``VectorizableStrategy``
    /// conformance and `config.taxRegime` for ``NoTaxes``; if both
    /// conditions are met, real MLX tensor dispatch is used instead.
    public func run(
        strategy: any Strategy,
        bars: [Bar],
        config: BacktestConfig
    ) async throws -> BacktestResult {
        return try await EventDrivenRunner().run(
            strategy: strategy,
            bars: bars,
            config: config
        )
    }
}
