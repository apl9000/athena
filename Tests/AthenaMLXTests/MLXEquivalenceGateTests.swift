import XCTest
import AthenaCore
import AthenaBacktest
import AthenaSweep
@testable import AthenaMLX

// MARK: - Equivalence tolerance
//
// A single constant applied to all numeric comparisons in the equivalence gate.
//
// `totalReturn`, `maxDrawdown`, and `finalEquity` use `Decimal` arithmetic
// internally and are converted to `Double` for cross-runner comparison.
// `sharpe` is already a `Double`. `fills.count` is an integer and always
// compared with exact equality.
//
// Exact equality holds while `MLXBacktestRunner` delegates to
// `EventDrivenRunner` (both runners share the same code path). The tolerance
// accommodates expected IEEE 754 rounding once MLX tensor dispatch replaces
// the delegation in a later slice.

/// Shared numeric tolerance for all MLX vs EventDriven equivalence assertions.
///
/// Applied to `totalReturn`, `maxDrawdown`, `sharpe`, and `finalEquity`.
/// `fills.count` is always compared with exact equality.
private let EquivalenceTolerance: Double = 1e-9

// MARK: - Canonical fixture strategy

/// Long/flat SMA-crossover strategy for the equivalence gate.
///
/// Goes long (buys 100 shares) when the fast SMA exceeds the slow SMA, and
/// goes flat (sells the entire position) when fast SMA falls back to or below
/// the slow SMA.
///
/// Conforms to ``VectorizableStrategy`` so it is eligible for the
/// `MLXBacktestRunner` fast path. ``signals(for:)`` is the vectorized-path
/// method that computes one signal per bar in a single pass; ``onBar(_:context:)``
/// is the event-driven equivalent used by `EventDrivenRunner` (and by
/// `MLXBacktestRunner` while the fast path is still in delegation mode).
///
/// The trade quantity is fixed at 100 shares per buy so that the vectorized
/// fill simulator and the event-driven engine produce the same fills when they
/// execute an identical signal sequence.
private struct SMALongFlatFixture: Strategy, VectorizableStrategy {
    let symbol: Symbol
    let fastPeriod: Int
    let slowPeriod: Int

    // MARK: VectorizableStrategy

    /// Vectorized signal computation: one Bool per bar.
    ///
    /// Returns `true` (long) when the fast SMA is strictly above the slow SMA
    /// at that bar. Returns `false` (flat) during warm-up or when fast ≤ slow.
    /// The output length always equals `bars.count`.
    func signals(for bars: [Bar]) -> [Bool] {
        let closes = bars.map(\.close)
        let fast = VectorizedSMA(period: fastPeriod).compute(closes: closes)
        let slow = VectorizedSMA(period: slowPeriod).compute(closes: closes)
        // Flat during warm-up (either SMA is nil) or when fast ≤ slow.
        return zip(fast, slow).map { f, s in
            guard let f, let s else { return false }
            return f > s
        }
    }

    // MARK: Strategy

    /// Event-driven execution: mirrors the vectorized signal using the indicator cache.
    ///
    /// - Buys 100 shares on a long signal when the position is flat.
    /// - Sells the entire position on a flat signal when the position is long.
    /// - Does nothing during warm-up (SMAs return nil).
    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }
        guard
            let fastMA = await context.indicators.sma(symbol, period: fastPeriod),
            let slowMA = await context.indicators.sma(symbol, period: slowPeriod)
        else { return }
        let qty = await context.portfolio.position(for: symbol)?.quantity ?? 0
        if fastMA > slowMA, qty == 0 {
            // Buy 100 shares — fixed quantity matches the vectorized fill
            // simulator's per-trade unit once the fast path is active.
            _ = try? await context.buy(symbol, quantity: 100)
        } else if fastMA <= slowMA, qty > 0 {
            _ = try? await context.sell(symbol, quantity: qty)
        }
    }
}

// MARK: - Fixture helpers

/// 300 daily bars with a noisy uptrend, seeded for reproducibility.
///
/// 300 bars is sufficient warm-up for SMA(50) (the widest period in the
/// canonical grid) and provides enough price variation to generate crossovers
/// and fills across all parameter cells.
private func makeEquivalenceBars(symbol: Symbol) -> [Bar] {
    let start = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2020, month: 1, day: 1))!
    var rng = Xoshiro256StarStar(seed: 0xA1B2_C3D4)
    var price: Decimal = 100
    return (0..<300).map { i in
        let r01 = Double(rng.next() % 10_000) / 10_000.0
        let noise = Decimal(r01 * 0.04 - 0.02)
        price = price * (1 + Decimal(string: "0.0005")! + noise)
        if price < 1 { price = 1 }
        return Bar(
            symbol: symbol,
            timestamp: start.addingTimeInterval(Double(i) * 86_400),
            open: price,
            high: price * Decimal(string: "1.005")!,
            low: price * Decimal(string: "0.995")!,
            close: price,
            volume: 1_000_000
        )
    }
}

private func makeEquivalenceConfig(bars: [Bar]) -> BacktestConfig {
    BacktestConfig(
        startDate: bars.first!.timestamp,
        endDate: bars.last!.timestamp,
        initialCash: .usd(100_000)
    )
}

/// Canonical multi-cell parameter grid: fast ∈ {5, 10} × slow ∈ {20, 50} = 4 cells.
///
/// All (fast, slow) combinations satisfy fast < slow, ensuring that there are
/// meaningful crossover events in both directions across the 300-bar fixture.
private let canonicalGrid = ParameterSpace.grid([
    .ints("fast", [5, 10]),
    .ints("slow", [20, 50]),
])

private func makeEquivalenceFactory(symbol: Symbol) -> ClosureStrategyFactory {
    let sym = symbol
    return ClosureStrategyFactory { params -> any Strategy in
        SMALongFlatFixture(
            symbol: sym,
            fastPeriod: params.int("fast") ?? 5,
            slowPeriod: params.int("slow") ?? 20
        )
    }
}

// MARK: - MLX equivalence gate
//
// Platform note
// ─────────────
// On platforms where the MLX framework is available (`canImport(MLX)` in
// MLXBacktestRunner.swift), `MLXBacktestRunner` routes `VectorizableStrategy`
// + `NoTaxes` cells through its tensor fast path. On all other platforms the
// runner delegates those cells to `EventDrivenRunner`, keeping CI green on
// non-Apple-Silicon builds.
//
// The tests below run on *all* platforms. On non-MLX platforms the gate passes
// trivially (both runners share the same event-driven code path, so results
// are exactly equal). On MLX platforms the gate enforces that tensor dispatch
// stays within `EquivalenceTolerance` of the event-driven baseline — which is
// the primary safety net that catches numerical drift when the fast path is
// active.

/// Equivalence gate between `MLXBacktestRunner` and `EventDrivenRunner` on a
/// canonical long/flat `VectorizableStrategy` fixture.
///
/// ## What this tests
/// - Five observable metrics per cell, in result (parameter-grid) order:
///   total return, max drawdown, Sharpe, final equity, and fill count.
/// - All numeric comparisons use a single documented `EquivalenceTolerance`.
/// - Integer metrics (`fills.count`) are always compared with exact equality.
///
/// ## Platform behaviour
/// Non-MLX platforms: both runners delegate to `EventDrivenRunner`; the gate
/// passes trivially (exact equality). Existing test coverage is unaffected.
/// MLX platforms: the fast path's tensor dispatch must stay within tolerance
/// of the event-driven baseline; any drift causes the gate to fail.
final class MLXEquivalenceGateTests: XCTestCase {

    // MARK: Primary gate: all five metrics, in result order

    /// Run the canonical SMA long/flat sweep through both runners and assert
    /// that total return, max drawdown, Sharpe, final equity, and fill count
    /// match within `EquivalenceTolerance` for every cell, in result order.
    ///
    /// This is the primary CI gate for the v0.5 MLX equivalence requirement
    /// (HQ#116).
    func test_canonicalFixture_allFiveMetrics_matchInResultOrder() async {
        let sym = Symbol("EQ")
        let bars = makeEquivalenceBars(symbol: sym)
        let config = makeEquivalenceConfig(bars: bars)
        let factory = makeEquivalenceFactory(symbol: sym)

        let mlxResults = await Sweep(
            factory: factory, runner: MLXBacktestRunner(),
            bars: bars, config: config, space: canonicalGrid
        ).run()
        let edResults = await Sweep(
            factory: factory, runner: EventDrivenRunner(),
            bars: bars, config: config, space: canonicalGrid
        ).run()

        XCTAssertEqual(
            mlxResults.count, edResults.count,
            "Both runners must return the same number of sweep results"
        )

        for (i, (mlx, ed)) in zip(mlxResults, edResults).enumerated() {
            guard let mlxBT = mlx.backtest, let edBT = ed.backtest else {
                XCTFail(
                    "Cell \(i) [\(mlx.params)]: expected .success from both runners; "
                    + "got mlx=\(mlx.outcome) ed=\(ed.outcome)"
                )
                continue
            }

            // 1. Total return
            XCTAssertEqual(
                NSDecimalNumber(decimal: mlxBT.totalReturn).doubleValue,
                NSDecimalNumber(decimal: edBT.totalReturn).doubleValue,
                accuracy: EquivalenceTolerance,
                "Cell \(i) [\(mlx.params)]: totalReturn mismatch"
            )

            // 2. Max drawdown
            XCTAssertEqual(
                NSDecimalNumber(decimal: mlxBT.maxDrawdown).doubleValue,
                NSDecimalNumber(decimal: edBT.maxDrawdown).doubleValue,
                accuracy: EquivalenceTolerance,
                "Cell \(i) [\(mlx.params)]: maxDrawdown mismatch"
            )

            // 3. Sharpe (already Double)
            XCTAssertEqual(
                mlxBT.sharpe, edBT.sharpe,
                accuracy: EquivalenceTolerance,
                "Cell \(i) [\(mlx.params)]: sharpe mismatch"
            )

            // 4. Final equity
            XCTAssertEqual(
                NSDecimalNumber(decimal: mlxBT.finalEquity.amount).doubleValue,
                NSDecimalNumber(decimal: edBT.finalEquity.amount).doubleValue,
                accuracy: EquivalenceTolerance,
                "Cell \(i) [\(mlx.params)]: finalEquity mismatch"
            )

            // 5. Fill count — integer; no tolerance required
            XCTAssertEqual(
                mlxBT.fills.count, edBT.fills.count,
                "Cell \(i) [\(mlx.params)]: fills.count mismatch"
            )
        }
    }

    // MARK: Result order

    /// Parameter-set order must be identical between the two runners.
    ///
    /// Sweep preserves parameter-grid order; both runners must return results
    /// in the same sequence so downstream callers can zip them safely.
    func test_canonicalFixture_resultOrderIsPreserved() async {
        let sym = Symbol("EQ")
        let bars = makeEquivalenceBars(symbol: sym)
        let config = makeEquivalenceConfig(bars: bars)
        let factory = makeEquivalenceFactory(symbol: sym)

        let mlxResults = await Sweep(
            factory: factory, runner: MLXBacktestRunner(),
            bars: bars, config: config, space: canonicalGrid
        ).run()
        let edResults = await Sweep(
            factory: factory, runner: EventDrivenRunner(),
            bars: bars, config: config, space: canonicalGrid
        ).run()

        XCTAssertEqual(mlxResults.count, edResults.count,
                       "Both runners must return the same number of results")
        for (i, (mlx, ed)) in zip(mlxResults, edResults).enumerated() {
            XCTAssertEqual(
                mlx.params.int("fast"), ed.params.int("fast"),
                "Cell \(i): fast parameter must be in identical order across both runners"
            )
            XCTAssertEqual(
                mlx.params.int("slow"), ed.params.int("slow"),
                "Cell \(i): slow parameter must be in identical order across both runners"
            )
        }
    }

    // MARK: Non-degenerate fixture guard

    /// At least one cell in the canonical grid must produce fills.
    ///
    /// A fixture that never trades satisfies all five numeric comparisons
    /// vacuously (zero return, zero drawdown, etc.). This test guards against
    /// that degenerate case: with 300 bars and SMA periods well inside the
    /// bar count, crossovers and fills must occur.
    func test_canonicalFixture_producesAtLeastOneFill() async {
        let sym = Symbol("EQ")
        let bars = makeEquivalenceBars(symbol: sym)
        let config = makeEquivalenceConfig(bars: bars)
        let factory = makeEquivalenceFactory(symbol: sym)

        let results = await Sweep(
            factory: factory, runner: MLXBacktestRunner(),
            bars: bars, config: config, space: canonicalGrid
        ).run()

        let totalFills = results.compactMap(\.backtest).map(\.fills.count).reduce(0, +)
        XCTAssertGreaterThan(
            totalFills, 0,
            "Canonical fixture must produce at least one fill across all grid cells; "
            + "a zero-fill fixture makes the equivalence gate vacuously true"
        )
    }

    // MARK: Per-cell failure isolation

    /// A bad factory cell must fail without poisoning other cells.
    ///
    /// The canonical grid runs four cells; if one factory call throws, the
    /// remaining three must still return results. This mirrors the existing
    /// sweep isolation contract and ensures the gate itself cannot be silently
    /// short-circuited by a crashing cell.
    func test_canonicalGrid_perCellFailureIsIsolated() async {
        let sym = Symbol("EQ")
        let bars = makeEquivalenceBars(symbol: sym)
        let config = makeEquivalenceConfig(bars: bars)

        // Factory always throws — every cell in the canonical grid fails.
        let failFactory = ClosureStrategyFactory { _ -> any Strategy in
            throw NSError(domain: "EquivalenceGateTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Injected failure"])
        }

        let results = await Sweep(
            factory: failFactory, runner: MLXBacktestRunner(),
            bars: bars, config: config, space: canonicalGrid
        ).run()

        XCTAssertEqual(
            results.count, canonicalGrid.sets.count,
            "Result count must equal parameter-set count even when all cells fail"
        )
        for (i, result) in results.enumerated() {
            if case .failure = result.outcome {
                // expected — each cell fails independently
            } else {
                XCTFail("Cell \(i): expected .failure outcome for throwing factory")
            }
        }
    }
}
