import XCTest
import AthenaCore
import AthenaBacktest
import AthenaSweep
@testable import AthenaMLX

// MARK: - Fixtures

/// A deterministic MA-crossover strategy used as a representative
/// real-world strategy for equivalence checks. Identical to the
/// MLXSweepExample's factory output for a given (fast, slow) pair.
private struct MACrossoverFixture: Strategy {
    let symbol: Symbol
    let fast: Int
    let slow: Int

    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }
        guard
            let fastMA = await context.indicators.sma(symbol, period: fast),
            let slowMA = await context.indicators.sma(symbol, period: slow)
        else { return }
        let qty = await context.portfolio.position(for: symbol)?.quantity ?? 0
        if fastMA > slowMA, qty == 0 {
            _ = try? await context.buy(symbol, quantity: 100)
        } else if fastMA < slowMA, qty > 0 {
            _ = try? await context.sell(symbol, quantity: qty)
        }
    }

    func onFinish(context: StrategyContext) async throws {
        if let pos = await context.portfolio.position(for: symbol), pos.quantity > 0 {
            try await context.sell(symbol, quantity: pos.quantity)
        }
    }
}

private func makeNoisyBars(
    _ n: Int,
    symbol: Symbol,
    seed: UInt64 = 42
) -> [Bar] {
    let start = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2020, month: 1, day: 1))!
    var rng = Xoshiro256StarStar(seed: seed)
    var price: Decimal = 100
    return (0..<n).map { i in
        let r01 = Double(rng.next() % 10_000) / 10_000.0
        let noise = Decimal(r01 * 0.04 - 0.02)
        price = price * (1 + Decimal(string: "0.0005")! + noise)
        if price < 1 { price = 1 }
        return Bar(
            symbol: symbol,
            timestamp: start.addingTimeInterval(Double(i) * 86_400),
            open: price, high: price * Decimal(string: "1.005")!,
            low: price * Decimal(string: "0.995")!, close: price,
            volume: 1_000_000
        )
    }
}

private func makeConfig(bars: [Bar]) -> BacktestConfig {
    BacktestConfig(
        startDate: bars.first!.timestamp,
        endDate: bars.last!.timestamp,
        initialCash: .usd(100_000)
    )
}

// MARK: - Value equivalence tests

/// Verifies that `MLXBacktestRunner` and `EventDrivenRunner` produce
/// numerically identical results for the same strategy, bars, and config.
///
/// These are the behaviour assertions that underpin the MLXSweepExample's
/// claim that switching runners is a one-line change that produces the
/// same results as the event-driven path.
final class MLXRunnerValueEquivalenceTests: XCTestCase {

    // MARK: Single-cell value equality

    /// `MLXBacktestRunner` and `EventDrivenRunner` must produce the same
    /// `totalReturn` for a buy-and-hold strategy on identical input.
    func test_singleCell_totalReturnMatchesEventDriven() async throws {
        let sym = Symbol("SYN")
        let bars = makeNoisyBars(200, symbol: sym)
        let config = makeConfig(bars: bars)
        let strategy = MACrossoverFixture(symbol: sym, fast: 10, slow: 50)

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: strategy, bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: strategy, bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.totalReturn, edResult.totalReturn,
            "totalReturn must be identical across both runners"
        )
    }

    /// `maxDrawdown` must match between both runners.
    func test_singleCell_maxDrawdownMatchesEventDriven() async throws {
        let sym = Symbol("SYN")
        let bars = makeNoisyBars(200, symbol: sym)
        let config = makeConfig(bars: bars)
        let strategy = MACrossoverFixture(symbol: sym, fast: 10, slow: 50)

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: strategy, bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: strategy, bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.maxDrawdown, edResult.maxDrawdown,
            "maxDrawdown must be identical across both runners"
        )
    }

    /// Fill count must match: the same trades must be executed regardless
    /// of which runner is used (in the v0.5 delegation model).
    func test_singleCell_fillCountMatchesEventDriven() async throws {
        let sym = Symbol("SYN")
        let bars = makeNoisyBars(200, symbol: sym)
        let config = makeConfig(bars: bars)
        let strategy = MACrossoverFixture(symbol: sym, fast: 10, slow: 50)

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: strategy, bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: strategy, bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.fills.count, edResult.fills.count,
            "Fill count must be identical across both runners"
        )
    }

    /// `finalEquity` must match: the same terminal portfolio value.
    func test_singleCell_finalEquityMatchesEventDriven() async throws {
        let sym = Symbol("SYN")
        let bars = makeNoisyBars(200, symbol: sym)
        let config = makeConfig(bars: bars)
        let strategy = MACrossoverFixture(symbol: sym, fast: 10, slow: 50)

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: strategy, bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: strategy, bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.finalEquity, edResult.finalEquity,
            "finalEquity must be identical across both runners"
        )
    }

    // MARK: Sweep-level value equality

    /// Every cell in a grid sweep must produce the same `totalReturn`
    /// from `MLXBacktestRunner` and `EventDrivenRunner`.
    func test_gridSweep_allCellsTotalReturnMatchEventDriven() async {
        let sym = Symbol("SYN")
        let bars = makeNoisyBars(500, symbol: sym)
        let config = makeConfig(bars: bars)
        let space = ParameterSpace.grid([
            .ints("fast", [5, 10, 20]),
            .ints("slow", [50, 100]),
        ])
        let sym2 = sym
        let factory = ClosureStrategyFactory { params -> any Strategy in
            MACrossoverFixture(
                symbol: sym2,
                fast: params.int("fast") ?? 10,
                slow: params.int("slow") ?? 50
            )
        }

        let mlxResults = await Sweep(
            factory: factory, runner: MLXBacktestRunner(),
            bars: bars, config: config, space: space
        ).run()
        let edResults = await Sweep(
            factory: factory, runner: EventDrivenRunner(),
            bars: bars, config: config, space: space
        ).run()

        XCTAssertEqual(mlxResults.count, edResults.count,
                       "Sweep must return the same number of results")

        for (mlx, ed) in zip(mlxResults, edResults) {
            guard let mlxBT = mlx.backtest, let edBT = ed.backtest else {
                XCTFail("Expected .success outcomes for params \(mlx.params)")
                continue
            }
            XCTAssertEqual(
                mlxBT.totalReturn, edBT.totalReturn,
                "totalReturn must match for params \(mlx.params)"
            )
            XCTAssertEqual(
                mlxBT.fills.count, edBT.fills.count,
                "fills.count must match for params \(mlx.params)"
            )
        }
    }

    // MARK: Non-vectorizable strategy falls back

    /// A strategy that does NOT conform to `VectorizableStrategy` still
    /// produces a valid result when run through `MLXBacktestRunner`.
    /// This confirms the fallback path works for every strategy type.
    func test_nonVectorizableStrategy_stillProducesValidResult() async throws {
        // MACrossoverFixture only conforms to Strategy (not VectorizableStrategy).
        let sym = Symbol("T")
        let bars = makeNoisyBars(100, symbol: sym)
        let config = makeConfig(bars: bars)
        let strategy = MACrossoverFixture(symbol: sym, fast: 5, slow: 20)

        let result = try await MLXBacktestRunner().run(
            strategy: strategy, bars: bars, config: config
        )

        XCTAssertEqual(result.initialEquity, config.initialCash,
                       "Non-vectorizable strategy must return initialEquity matching config")
    }
}
