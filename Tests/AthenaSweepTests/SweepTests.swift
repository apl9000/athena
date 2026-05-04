import XCTest
import AthenaCore
import AthenaIndicators
import AthenaBrokers
import AthenaData
import AthenaBacktest
@testable import AthenaSweep

// MARK: - Test fixtures

/// A trivial strategy that buys `quantity` shares once on the first bar
/// and holds. The quantity comes from the parameter set so different
/// parameter values produce different final equity values.
private struct BuyOnceStrategy: Strategy {
    let symbol: Symbol
    let quantity: Decimal
    private let bought = OnceFlag()
    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }
        if await bought.value { return }
        try await context.buy(symbol, quantity: quantity)
        await bought.set(true)
    }
}

private actor OnceFlag {
    private var v = false
    var value: Bool { v }
    func set(_ x: Bool) { v = x }
}

private struct AlwaysFailStrategy: Strategy {
    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        throw NSError(domain: "Test", code: 1, userInfo: nil)
    }
}

private func bars(_ count: Int, sym: Symbol = Symbol("X")) -> [Bar] {
    let cal = Calendar(identifier: .gregorian)
    let start = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
    var out: [Bar] = []
    for i in 0..<count {
        let p: Decimal = 100 + Decimal(i)
        out.append(Bar(
            symbol: sym,
            timestamp: start.addingTimeInterval(Double(i) * 86_400),
            open: p, high: p + 1, low: p - 1, close: p,
            volume: 1_000_000
        ))
    }
    return out
}

// MARK: - SweepTests

final class SweepTests: XCTestCase {

    func testSweepRunsAllCellsInOrder() async {
        let bs = bars(20)
        let space = ParameterSpace.grid([.ints("qty", [1, 2, 3, 4])])
        let factory = ClosureStrategyFactory { params in
            BuyOnceStrategy(
                symbol: Symbol("X"),
                quantity: Decimal(params.int("qty") ?? 0)
            )
        }
        let config = BacktestConfig(
            startDate: bs.first!.timestamp,
            endDate: bs.last!.timestamp,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        let sweep = Sweep(
            factory: factory, bars: bs, config: config, space: space, concurrency: 2
        )
        let results = await sweep.run()
        XCTAssertEqual(results.count, 4)
        // Order matches input
        XCTAssertEqual(results.map { $0.params.int("qty") }, [1, 2, 3, 4])
        // All succeeded
        for r in results {
            XCTAssertNotNil(r.backtest, "expected success for \(r.params)")
        }
        // Different qty → different final equity (more shares = bigger swing)
        let equities = results.compactMap { $0.backtest?.finalEquity.amount }
        XCTAssertEqual(Set(equities).count, 4)
    }

    func testSweepEmptySpaceReturnsEmpty() async {
        let bs = bars(5)
        let config = BacktestConfig(
            startDate: bs.first!.timestamp,
            endDate: bs.last!.timestamp,
            initialCash: .usd(1_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        let factory = ClosureStrategyFactory { _ in BuyOnceStrategy(symbol: Symbol("X"), quantity: 1) }
        let sweep = Sweep(
            factory: factory, bars: bs, config: config, space: ParameterSpace([])
        )
        let results = await sweep.run()
        XCTAssertTrue(results.isEmpty)
    }

    func testSweepIsolatesPerCellFailures() async {
        let bs = bars(10)
        let space = ParameterSpace.grid([.ints("mode", [0, 1, 0, 1])])
        let factory = ClosureStrategyFactory { params -> any Strategy in
            if params.int("mode") == 1 {
                return AlwaysFailStrategy()
            } else {
                return BuyOnceStrategy(symbol: Symbol("X"), quantity: 1)
            }
        }
        let config = BacktestConfig(
            startDate: bs.first!.timestamp,
            endDate: bs.last!.timestamp,
            initialCash: .usd(5_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        let sweep = Sweep(
            factory: factory, bars: bs, config: config, space: space
        )
        let results = await sweep.run()
        XCTAssertEqual(results.count, 4)
        var successes = 0
        var failures = 0
        for r in results {
            switch r.outcome {
            case .success: successes += 1
            case .failure: failures += 1
            }
        }
        // mode=0 succeeds, mode=1 fails — but `grid` over a single axis with
        // duplicate values dedupes via Cartesian semantics... actually grid
        // preserves duplicates because it treats them as distinct list
        // entries. Two of each.
        XCTAssertEqual(successes, 2)
        XCTAssertEqual(failures, 2)
    }

    func testFactoryThrowingIsCapturedAsFailure() async {
        let bs = bars(5)
        let space = ParameterSpace.grid([.ints("x", [1, 2])])
        struct Boom: Error {}
        let factory = ClosureStrategyFactory { _ -> any Strategy in throw Boom() }
        let config = BacktestConfig(
            startDate: bs.first!.timestamp,
            endDate: bs.last!.timestamp,
            initialCash: .usd(1_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        let sweep = Sweep(factory: factory, bars: bs, config: config, space: space)
        let results = await sweep.run()
        XCTAssertEqual(results.count, 2)
        for r in results {
            if case .failure = r.outcome {} else { XCTFail("expected failure") }
        }
    }

    func testConcurrencyOneEqualsSerial() async {
        // Sanity: concurrency=1 should still produce identical results.
        let bs = bars(15)
        let space = ParameterSpace.grid([.ints("qty", [1, 2, 3])])
        let factory = ClosureStrategyFactory { params in
            BuyOnceStrategy(
                symbol: Symbol("X"),
                quantity: Decimal(params.int("qty") ?? 0)
            )
        }
        let config = BacktestConfig(
            startDate: bs.first!.timestamp,
            endDate: bs.last!.timestamp,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        let serial = await Sweep(
            factory: factory, bars: bs, config: config, space: space, concurrency: 1
        ).run()
        let parallel = await Sweep(
            factory: factory, bars: bs, config: config, space: space, concurrency: 8
        ).run()
        XCTAssertEqual(serial.count, parallel.count)
        for (a, b) in zip(serial, parallel) {
            XCTAssertEqual(a.params.int("qty"), b.params.int("qty"))
            XCTAssertEqual(a.backtest?.finalEquity.amount, b.backtest?.finalEquity.amount)
        }
    }
}
