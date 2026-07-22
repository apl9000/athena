import AthenaCore
import AthenaBacktest
import AthenaSweep

// MARK: - MLXBacktestRunner

/// A ``BacktestRunner`` with an MLX-backed fast path for vectorizable
/// strategies on Apple Silicon (macOS / iOS).
///
/// ## Fast-path eligibility
/// - The strategy must conform to ``VectorizableStrategy``.
/// - The ``BacktestConfig`` must use ``NoTaxes`` (tax-regime vectorization
///   is out of scope for v0.5).
///
/// When neither condition is met the runner transparently falls back to
/// ``EventDrivenRunner`` per cell, so callers never need to handle the
/// dispatch themselves.
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

    public func run(
        strategy: any Strategy,
        bars: [Bar],
        config: BacktestConfig
    ) async throws -> BacktestResult {
        // Fast path: VectorizableStrategy + NoTaxes regime.
        if let vs = strategy as? any VectorizableStrategy,
           config.taxRegime is NoTaxes {
            return vectorizedRun(strategy: vs, bars: bars, config: config)
        }
        // Fallback: full event-driven engine.
        // Issue #114 will add explicit tests and documentation for the
        // non-VectorizableStrategy and non-NoTaxes fallback paths.
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
    ) -> BacktestResult {
        // Filter and sort — same semantics as BacktestEngine.
        let filteredBars = bars
            .filter { $0.timestamp >= config.startDate && $0.timestamp <= config.endDate }
            .sorted { $0.timestamp < $1.timestamp }

        // Determine the primary symbol from the bar sequence.
        // v0.5 scope: single-symbol strategies.
        let symbol = filteredBars.first?.symbol ?? Symbol("UNKNOWN")

        // Obtain signals (must match filteredBars.count by VectorizableStrategy contract).
        let signals = strategy.signals(for: filteredBars)

        // Guard against a mismatch — surface it as a BacktestResult with
        // initialEquity == finalEquity so callers can detect it without crashing.
        guard signals.count == filteredBars.count else {
            return BacktestResult(
                initialEquity: config.initialCash,
                finalEquity: config.initialCash,
                snapshots: [],
                fills: []
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
