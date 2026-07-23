import XCTest
import AthenaCore
import AthenaBacktest
import AthenaSweep
@testable import AthenaMLX

// MARK: - Equivalence tolerance
//
// What "equivalence" means once the vectorized fast path is active
// ────────────────────────────────────────────────────────────────
// The two runners intentionally differ in position sizing: the
// `VectorizableStrategy` contract is "fully in" (the simulator buys
// floor(availableCash / fillPrice) shares at the next open), while an
// event-driven strategy cannot know the next bar's open at order-submission
// time and therefore cannot reproduce that quantity exactly. Equity-level
// metrics are consequently NOT comparable across runners.
//
// The gate therefore asserts two things:
// 1. Cross-runner *fill structure* equivalence — both runners must produce
//    the same number of fills, on the same bars, on the same sides, at the
//    same prices. This proves the vectorized signal → fill translation
//    matches the event-driven engine's timing and pricing semantics.
// 2. Vectorized *metrics* against golden values captured from the seeded,
//    deterministic canonical fixture. This is the drift net that catches
//    numerical changes when MLX tensor ops replace the Swift loops.

/// Tolerance for cross-runner fill-price comparisons and golden-value
/// ratio metrics (`totalReturn`, `maxDrawdown`, `sharpe`).
private let EquivalenceTolerance: Double = 1e-6

/// Tolerance for golden `finalEquity` comparisons (dollar scale).
private let EquityTolerance: Double = 0.01

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
/// The event-driven path trades a fixed 100 shares per buy; the vectorized
/// path trades all-in per the ``VectorizableStrategy`` contract. Sizing
/// therefore differs by design — the gate compares fill structure (count,
/// timing, side, price), not equity, across runners.
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

    /// Pre-register both SMAs so the indicator cache feeds them from bar 0.
    /// Without this, lazily-created indicators start one bar late (documented
    /// Indicators caveat), shifting crossovers near the warm-up boundary and
    /// breaking fill-structure equivalence with the vectorized path.
    func onStart(context: StrategyContext) async throws {
        _ = await context.indicators.sma(symbol, period: fastPeriod)
        _ = await context.indicators.sma(symbol, period: slowPeriod)
    }

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

// MARK: - Golden values
//
// Captured from the seeded canonical fixture (Xoshiro256** seed 0xA1B2_C3D4,
// 300 bars, Decimal arithmetic) with the pure-Swift vectorized fast path.
// Regenerate by printing the vectorized sweep results if the fixture, the
// fill contract, or the metric definitions intentionally change.
private struct GoldenCell {
    let fast: Int
    let slow: Int
    let fills: Int
    let totalReturn: Double
    let maxDrawdown: Double
    let sharpe: Double
    let finalEquity: Double
}

private let goldenCells: [GoldenCell] = [
    GoldenCell(fast: 5,  slow: 20, fills: 15, totalReturn: -0.07301775311022075,
               maxDrawdown: 0.17834115962037883, sharpe: -0.46116569558400955,
               finalEquity: 92_698.22468897786),
    GoldenCell(fast: 5,  slow: 50, fills: 13, totalReturn: -0.0885532531484274,
               maxDrawdown: 0.1958997936588363, sharpe: -0.622992349646425,
               finalEquity: 91_144.67468515722),
    GoldenCell(fast: 10, slow: 20, fills: 15, totalReturn: -0.028595590759415635,
               maxDrawdown: 0.1722558081460317, sharpe: -0.14369920190938312,
               finalEquity: 97_140.44092405846),
    GoldenCell(fast: 10, slow: 50, fills: 11, totalReturn: -0.05600762337800874,
               maxDrawdown: 0.1924136492571617, sharpe: -0.3459208053246339,
               finalEquity: 94_399.23766219914),
]

// MARK: - MLX equivalence gate

/// Equivalence gate between `MLXBacktestRunner` and `EventDrivenRunner` on a
/// canonical long/flat `VectorizableStrategy` fixture.
///
/// ## What this tests
/// - **Cross-runner fill structure**: both runners must produce the same
///   number of fills per cell, on the same bars, same sides, same prices.
///   Position *sizing* intentionally differs (see `EquivalenceTolerance`
///   note above), so equity metrics are not compared across runners.
/// - **Vectorized metrics vs goldens**: total return, max drawdown, Sharpe,
///   final equity, and fill count per cell, pinned to values captured from
///   the deterministic fixture. This catches numerical drift when MLX tensor
///   dispatch replaces the pure-Swift loops (HQ#116).
final class MLXEquivalenceGateTests: XCTestCase {

    // MARK: Primary gate: fill structure + golden metrics, in result order

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
        XCTAssertEqual(
            mlxResults.count, goldenCells.count,
            "Golden table must cover every canonical grid cell"
        )

        for (i, (mlx, ed)) in zip(mlxResults, edResults).enumerated() {
            guard let mlxBT = mlx.backtest, let edBT = ed.backtest else {
                XCTFail(
                    "Cell \(i) [\(mlx.params)]: expected .success from both runners; "
                    + "got mlx=\(mlx.outcome) ed=\(ed.outcome)"
                )
                continue
            }

            // ── Cross-runner fill structure ──────────────────────────────
            XCTAssertEqual(
                mlxBT.fills.count, edBT.fills.count,
                "Cell \(i) [\(mlx.params)]: fills.count mismatch across runners"
            )
            for (j, (mf, ef)) in zip(mlxBT.fills, edBT.fills).enumerated() {
                XCTAssertEqual(
                    mf.filledAt, ef.filledAt,
                    "Cell \(i) fill \(j): timestamp mismatch across runners"
                )
                XCTAssertEqual(
                    mf.side, ef.side,
                    "Cell \(i) fill \(j): side mismatch across runners"
                )
                XCTAssertEqual(
                    NSDecimalNumber(decimal: mf.price).doubleValue,
                    NSDecimalNumber(decimal: ef.price).doubleValue,
                    accuracy: EquivalenceTolerance,
                    "Cell \(i) fill \(j): price mismatch across runners"
                )
            }

            // ── Vectorized metrics vs goldens ────────────────────────────
            let golden = goldenCells[i]
            XCTAssertEqual(mlx.params.int("fast"), golden.fast,
                           "Cell \(i): golden table out of sync with grid order")
            XCTAssertEqual(mlx.params.int("slow"), golden.slow,
                           "Cell \(i): golden table out of sync with grid order")
            XCTAssertEqual(
                mlxBT.fills.count, golden.fills,
                "Cell \(i) [\(mlx.params)]: fills.count drifted from golden"
            )
            XCTAssertEqual(
                NSDecimalNumber(decimal: mlxBT.totalReturn).doubleValue,
                golden.totalReturn,
                accuracy: EquivalenceTolerance,
                "Cell \(i) [\(mlx.params)]: totalReturn drifted from golden"
            )
            XCTAssertEqual(
                NSDecimalNumber(decimal: mlxBT.maxDrawdown).doubleValue,
                golden.maxDrawdown,
                accuracy: EquivalenceTolerance,
                "Cell \(i) [\(mlx.params)]: maxDrawdown drifted from golden"
            )
            XCTAssertEqual(
                mlxBT.sharpe, golden.sharpe,
                accuracy: EquivalenceTolerance,
                "Cell \(i) [\(mlx.params)]: sharpe drifted from golden"
            )
            XCTAssertEqual(
                NSDecimalNumber(decimal: mlxBT.finalEquity.amount).doubleValue,
                golden.finalEquity,
                accuracy: EquityTolerance,
                "Cell \(i) [\(mlx.params)]: finalEquity drifted from golden"
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
