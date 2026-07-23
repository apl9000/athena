import AthenaCore
import AthenaBacktest
import AthenaSweep

// MARK: - MLXBacktestRunner

/// A ``BacktestRunner`` with an MLX-backed fast path for vectorizable
/// strategies on Apple Silicon (macOS / iOS).
///
/// ## Fast-path eligibility
/// All conditions must be met for a cell to take the MLX fast path:
/// 1. The strategy conforms to ``VectorizableStrategy``.
/// 2. The ``BacktestConfig`` uses ``NoTaxes`` (tax-regime vectorization
///    is out of scope for v0.5).
/// 3. The ``BacktestConfig`` uses ``NoCorporateActions``.
/// 4. The bar sequence covers at most one symbol.
///
/// ## Fallback behaviour
/// When either condition is not met, the runner transparently routes
/// the cell to ``EventDrivenRunner``. Callers never need to detect or
/// handle the dispatch themselves — the result shape is always the
/// same ``BacktestResult`` regardless of which path ran.
///
/// Explicit fallback triggers:
/// - **Non-`VectorizableStrategy`**: any strategy that does not implement
///   ``VectorizableStrategy/signals(for:)`` is routed through
///   ``EventDrivenRunner`` on a per-cell basis.
/// - **Non-`NoTaxes` tax regime**: any ``BacktestConfig`` whose
///   `taxRegime` is not ``NoTaxes`` (e.g. ``USWashSale``,
///   ``CanadianACB``) always falls back to ``EventDrivenRunner``.
///
/// ## v0.5 fast path
/// For eligible cells, `MLXBacktestRunner` calls
/// ``VectorizableStrategy/signals(for:)`` to obtain a per-bar long/flat
/// signal array, then simulates fills and computes equity purely in Swift
/// without spinning up the full actor-based backtest infrastructure.  In
/// a later slice the inner loops will be replaced with MLX tensor
/// operations behind `#if canImport(MLX)` guards; the observable
/// `BacktestResult` shape is unchanged.
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

    /// Run one backtest cell, routing to the vectorized fast path when
    /// eligible or falling back to ``EventDrivenRunner`` otherwise.
    /// Result shape is identical across both paths.
    public func run(
        strategy: any Strategy,
        bars: [Bar],
        config: BacktestConfig
    ) async throws -> BacktestResult {
        // Fast path: VectorizableStrategy + NoTaxes + NoCorporateActions + single symbol.
        if let vs = strategy as? any VectorizableStrategy,
           config.taxRegime is NoTaxes,
           config.corporateActions is NoCorporateActions,
           Set(bars.map(\.symbol)).count <= 1 {
            return try vectorizedRun(strategy: vs, bars: bars, config: config)
        }
        // Explicit fallback: full event-driven engine (see MLXFallbackTests, #114).
        return try await EventDrivenRunner().run(
            strategy: strategy,
            bars: bars,
            config: config
        )
    }

    // MARK: - Vectorized execution

    /// Execute a single backtest cell via the vectorized fill simulator.
    ///
    /// Steps:
    ///  1. Filter and sort bars to the config date window (mirrors BacktestEngine).
    ///  2. Obtain signals from the strategy's `signals(for:)` method.
    ///  3. Simulate fills and equity reduction with `VectorizedFillSimulator`.
    ///  4. Wrap into a `BacktestResult`.
    private func vectorizedRun(
        strategy: any VectorizableStrategy,
        bars: [Bar],
        config: BacktestConfig
    ) throws -> BacktestResult {
        // Filter and sort — same semantics as BacktestEngine.
        let filteredBars = bars
            .filter { $0.timestamp >= config.startDate && $0.timestamp <= config.endDate }
            .sorted { $0.timestamp < $1.timestamp }

        // Determine the primary symbol from the bar sequence.
        // v0.5 scope: single-symbol strategies.
        let symbol = filteredBars.first?.symbol ?? Symbol("UNKNOWN")

        // Obtain signals (must match filteredBars.count by VectorizableStrategy contract).
        let signals = strategy.signals(for: filteredBars)

        // Contract violation: signal count must match bar count.
        guard signals.count == filteredBars.count else {
            throw VectorizedFillSimulatorError.signalCountMismatch(
                signalCount: signals.count, barCount: filteredBars.count
            )
        }

        let sim = VectorizedFillSimulator()
        let result = sim.simulate(
            symbol: symbol,
            signals: signals,
            bars: filteredBars,
            initialCash: config.initialCash,
            commission: config.commission,
            slippage: config.slippage
        )

        return BacktestResult(
            initialEquity: config.initialCash,
            finalEquity: result.finalEquity,
            snapshots: result.snapshots,
            fills: result.fills
        )
    }
}
