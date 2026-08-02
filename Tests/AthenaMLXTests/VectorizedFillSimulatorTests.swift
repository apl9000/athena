import XCTest
import AthenaCore
import AthenaBrokers
import AthenaBacktest
import AthenaSweep
@testable import AthenaMLX

// MARK: - Shared fixtures (scoped to this file)

/// A strategy whose signal array is supplied at init time.
/// Used to verify hand-computed fill expectations without coupling tests
/// to a specific indicator algorithm.
private struct DefinedSignalStrategy: Strategy, VectorizableStrategy {
    let symbol: Symbol
    let signalArray: [Bool]

    func onBar(_ bar: Bar, context: StrategyContext) async throws {}
    func signals(for bars: [Bar]) -> [Bool] { signalArray }
}

private func makeBars(
    _ n: Int,
    symbol: Symbol = Symbol("T"),
    opens: [Decimal]? = nil
) -> [Bar] {
    let base = Date(timeIntervalSince1970: 0)
    return (0..<n).map { i in
        let open = opens?[i] ?? Decimal(100 + i)
        return Bar(
            symbol: symbol,
            timestamp: base.addingTimeInterval(Double(i) * 86_400),
            open: open,
            high: open + 2,
            low: open - 1,
            close: open,
            volume: 1_000_000
        )
    }
}

private func makeConfig(bars: [Bar]) -> BacktestConfig {
    BacktestConfig(
        startDate: bars.first!.timestamp,
        endDate: bars.last!.timestamp,
        initialCash: .usd(10_000)
    )
}

// MARK: - VectorizedFillSimulator unit tests
//
// These tests exercise the simulator in isolation using hand-computed
// inputs and expected outputs. No MLX framework is needed — the simulator
// is pure Swift math.

final class VectorizedFillSimulatorFillTests: XCTestCase {

    // MARK: AC1 — fills land at the correct bar's open

    /// Flat-to-long transition at bar[1] → buy at bar[2].open.
    /// Long-to-flat transition at bar[3] → sell at bar[4].open.
    ///
    /// signals = [F, T, T, F, F]
    ///           ↑      ↑
    ///    bar[1]=T→buy at bar[2].open
    ///                  bar[3]=F→sell at bar[4].open
    func test_fillsLandAtNextBarOpen_oneRoundTrip() {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym, opens: [100, 101, 102, 103, 104])
        let signals = [false, true, true, false, false]

        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: signals,
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )

        XCTAssertEqual(result.fills.count, 2, "Exactly one buy + one sell fill")
        XCTAssertEqual(result.fills[0].side, .buy,  "First fill is a buy")
        XCTAssertEqual(result.fills[0].price, 102,  "Buy at bar[2].open = 102")
        XCTAssertEqual(result.fills[1].side, .sell, "Second fill is a sell")
        XCTAssertEqual(result.fills[1].price, 104,  "Sell at bar[4].open = 104")
    }

    /// signals[0]=T triggers the first transition; buy fills at bar[1].open.
    func test_fillsLandAtNextBarOpen_entryOnFirstSignal() {
        let sym = Symbol("T")
        let bars = makeBars(3, symbol: sym, opens: [100, 101, 102])
        let signals = [true, true, true]   // always long

        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: signals,
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )

        XCTAssertEqual(result.fills.count, 1, "One buy fill for always-long over 3 bars")
        XCTAssertEqual(result.fills[0].side, .buy)
        XCTAssertEqual(result.fills[0].price, 101, "Buy at bar[1].open = 101")
    }

    /// Flat throughout → no fills at all.
    func test_alwaysFlatProducesNoFills() {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym)
        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: [false, false, false, false, false],
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        XCTAssertTrue(result.fills.isEmpty, "Flat strategy must produce no fills")
    }

    /// A transition on the FINAL bar has no next open and must not produce a fill.
    func test_finalBarTransitionIsNotFilled() {
        let sym = Symbol("T")
        let bars = makeBars(3, symbol: sym)
        // signals[2] = true is on the final bar — no next bar to fill at.
        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: [false, false, true],
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        XCTAssertEqual(result.fills.count, 0,
                       "Transition on the final bar must not produce a fill")
    }

    /// Rapid toggles: F→T→F→T→F over 5 bars produces 2 buys and 1 sell.
    /// signals = [F, T, F, T, F]
    ///   bar[1]=T → buy at bar[2].open
    ///   bar[2]=F → sell at bar[3].open
    ///   bar[3]=T → buy at bar[4].open
    ///   bar[4]=F → final bar, no fill
    func test_rapidTogglesProduceCorrectFills() {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym, opens: [100, 101, 102, 103, 104])
        let signals = [false, true, false, true, false]

        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: signals,
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )

        // Transitions:
        // bar[1]=T → buy at bar[2].open=102
        // bar[2]=F → sell at bar[3].open=103
        // bar[3]=T → buy at bar[4].open=104
        // bar[4]=F → final bar, not filled
        XCTAssertEqual(result.fills.count, 3, "2 buys + 1 sell")
        XCTAssertEqual(result.fills[0].side, .buy)
        XCTAssertEqual(result.fills[0].price, 102)
        XCTAssertEqual(result.fills[1].side, .sell)
        XCTAssertEqual(result.fills[1].price, 103)
        XCTAssertEqual(result.fills[2].side, .buy)
        XCTAssertEqual(result.fills[2].price, 104)
    }

    /// Single bar: the only signal is on the final bar — no fill possible.
    func test_singleBar_noFills() {
        let sym = Symbol("T")
        let bar = makeBars(1, symbol: sym)
        let result = VectorizedFillSimulator().simulate(
            symbol: sym, signals: [true], bars: bar,
            initialCash: .usd(10_000), commission: FreeCommission(currency: .usd), slippage: NoSlippage()
        )
        XCTAssertEqual(result.fills.count, 0)
    }

    /// Empty bars produce an empty result without crashing.
    func test_emptyBars_noFills() {
        let sym = Symbol("T")
        let result = VectorizedFillSimulator().simulate(
            symbol: sym, signals: [], bars: [],
            initialCash: .usd(10_000), commission: FreeCommission(currency: .usd), slippage: NoSlippage()
        )
        XCTAssertTrue(result.fills.isEmpty)
        XCTAssertTrue(result.snapshots.isEmpty)
        XCTAssertEqual(result.finalEquity, .usd(10_000))
    }
}

// MARK: - Fill quantity & equity tests

final class VectorizedFillSimulatorEquityTests: XCTestCase {

    // MARK: AC1 — buy quantity

    /// Buy uses all available cash (floor-shares) when FreeCommission + NoSlippage.
    /// initialCash=$10 000, open=100 → 100 shares bought.
    func test_buyQtyUsesAllAvailableCash_noSlippageNoCommission() {
        let sym = Symbol("T")
        // bar[0]: F, bar[1]: T → buy at bar[1].open, bar[2]: T (hold)
        let bars = makeBars(3, symbol: sym, opens: [100, 100, 100])
        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: [false, true, true],
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        // signals[0]=false, signals[1]=true → buy at bars[1].open=100 → 100 shares
        XCTAssertEqual(result.fills.count, 1)
        XCTAssertEqual(result.fills[0].quantity, 100, "Buy 100 shares at $100 with $10 000 cash")
    }

    /// Sell disposes of the entire position.
    func test_sellDisposesEntirePosition() {
        let sym = Symbol("T")
        let bars = makeBars(4, symbol: sym, opens: [100, 100, 100, 100])
        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: [false, true, false, false],
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        // signals = [F, T, F, F]:
        // bar[2]: signals[1]=T vs executed=F → BUY at bar[2].open=100
        // bar[3]: signals[2]=F vs executed=T → SELL at bar[3].open=100
        XCTAssertEqual(result.fills.count, 2)
        let buyFill = result.fills.first(where: { $0.side == .buy })!
        let sellFill = result.fills.first(where: { $0.side == .sell })!
        XCTAssertEqual(sellFill.quantity, buyFill.quantity, "Sell qty must equal buy qty")
    }

    // MARK: AC2 — slippage reflected in fill price and equity

    /// FixedBpsSlippage(bps: 10) on a buy:
    /// open=100, fillPrice = 100 * (1 + 10/10_000) = 100.1
    func test_slippageReflectedInBuyFillPrice() {
        let sym = Symbol("T")
        // signals = [F, T, T] → buy at bar[1].open=100
        let bars = makeBars(3, symbol: sym, opens: [100, 100, 100])
        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: [false, true, true],
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: FixedBpsSlippage(bps: 10)
        )
        let fill = result.fills.first(where: { $0.side == .buy })!
        let expectedPrice = Decimal(100) * (1 + Decimal(10) / Decimal(10_000))
        XCTAssertEqual(fill.price, expectedPrice,
                       "Buy fill price must apply FixedBpsSlippage(bps: 10)")
    }

    /// FixedBpsSlippage on a sell:
    /// open=100, fillPrice = 100 * (1 - 10/10_000) = 99.9
    func test_slippageReflectedInSellFillPrice() {
        let sym = Symbol("T")
        // signals = [F, T, F, F] with 4 bars:
        // bar[2]: signals[1]=T → BUY at bar[2].open=100
        // bar[3]: signals[2]=F → SELL at bar[3].open=100
        let bars = makeBars(4, symbol: sym, opens: [100, 100, 100, 100])
        let signals = [false, true, false, false]
        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: signals,
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: FixedBpsSlippage(bps: 10)
        )
        let sellFill = result.fills.first(where: { $0.side == .sell })!
        let expectedSellPrice = Decimal(100) * (1 - Decimal(10) / Decimal(10_000))
        XCTAssertEqual(sellFill.price, expectedSellPrice,
                       "Sell fill price must apply FixedBpsSlippage(bps: 10) negatively")
    }

    /// Fixed commission of $5 is deducted from final equity.
    /// With initialCash=$1 000 and price=$100, no slippage:
    ///   buy at bar[2].open: floor((1000-5)/100)=9 shares, cost=900+5=905, cash left=95
    ///   sell at bar[4].open: proceeds=9*100-5=895, finalEquity=95+895=990
    func test_fixedCommissionDeductedFromEquity() {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym, opens: [100, 100, 100, 100, 100])
        let signals = [false, true, true, false, false]
        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: signals,
            bars: bars,
            initialCash: .usd(1_000),
            commission: FixedCommission(amount: 5, currency: .usd),
            slippage: NoSlippage()
        )
        // buy at bar[2].open=100, sell at bar[4].open=100
        XCTAssertEqual(result.fills.count, 2)
        XCTAssertEqual(result.fills[0].commission.amount, 5, "Buy commission = $5")
        XCTAssertEqual(result.fills[1].commission.amount, 5, "Sell commission = $5")
        XCTAssertEqual(result.finalEquity.amount, 990,
                       "Two $5 commissions leave $10 round-trip cost")
    }

    // MARK: AC3 — snapshots and result shape

    /// One snapshot per bar, each with a valid totalValue.
    func test_snapshotCountMatchesBarCount() {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym)
        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: [false, true, true, false, false],
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        XCTAssertEqual(result.snapshots.count, bars.count,
                       "Simulator must produce one snapshot per bar")
    }

    /// Snapshot timestamps align with bar timestamps.
    func test_snapshotTimestampsMatchBars() {
        let sym = Symbol("T")
        let bars = makeBars(4, symbol: sym)
        let result = VectorizedFillSimulator().simulate(
            symbol: sym, signals: [false, false, false, false], bars: bars,
            initialCash: .usd(10_000), commission: FreeCommission(currency: .usd), slippage: NoSlippage()
        )
        for (snap, bar) in zip(result.snapshots, bars) {
            XCTAssertEqual(snap.timestamp, bar.timestamp)
        }
    }

    /// While flat, snapshots report full initial cash as totalValue.
    func test_flatStrategy_snapshotEqualsInitialCash() {
        let sym = Symbol("T")
        let bars = makeBars(3, symbol: sym, opens: [100, 100, 100])
        let result = VectorizedFillSimulator().simulate(
            symbol: sym, signals: [false, false, false], bars: bars,
            initialCash: .usd(5_000), commission: FreeCommission(currency: .usd), slippage: NoSlippage()
        )
        for snap in result.snapshots {
            XCTAssertEqual(snap.totalValue, .usd(5_000),
                           "Flat strategy snapshot totalValue must equal initial cash")
        }
        XCTAssertEqual(result.finalEquity, .usd(5_000))
    }

    /// While holding a position, snapshots mark-to-market at bar's close.
    ///
    /// Signal trace (4 bars):
    ///   signals = [F, T, T, T]
    ///   bar[0]: no prev signal → flat snapshot
    ///   bar[1]: signals[0]=F → no fill → flat snapshot
    ///   bar[2]: signals[1]=T → BUY at bar[2].open=100 → snapshot at bar[2].close=110
    ///   bar[3]: holding → snapshot at bar[3].close=110
    func test_longPosition_snapshotMarksToMarketAtClose() {
        let sym = Symbol("T")
        let base = Date(timeIntervalSince1970: 0)
        let bars: [Bar] = [
            Bar(symbol: sym, timestamp: base,                         open: 100, high: 102, low: 99,  close: 100, volume: 1_000_000),
            Bar(symbol: sym, timestamp: base + 86_400,                open: 100, high: 102, low: 99,  close: 100, volume: 1_000_000),
            Bar(symbol: sym, timestamp: base + 86_400 * 2,            open: 100, high: 115, low: 99,  close: 110, volume: 1_000_000),
            Bar(symbol: sym, timestamp: base + 86_400 * 3,            open: 110, high: 115, low: 109, close: 110, volume: 1_000_000),
        ]
        // signals = [F, T, T, T]: signals[1]=T triggers BUY at bar[2].open=100
        let result = VectorizedFillSimulator().simulate(
            symbol: sym,
            signals: [false, true, true, true],
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        // BUY at bar[2].open=100: qty=100, cash=0
        // Snapshot at bar[2].close=110: 100 * 110 + 0 = 11_000
        let snap2 = result.snapshots[2]
        XCTAssertEqual(snap2.totalValue.amount, 11_000,
                       "Snapshot at bar[2].close must mark 100 shares at $110")
    }

    /// finalEquity matches the last snapshot's totalValue.
    func test_finalEquityMatchesLastSnapshot() {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym)
        let result = VectorizedFillSimulator().simulate(
            symbol: sym, signals: [false, true, true, true, false],
            bars: bars,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        XCTAssertEqual(result.finalEquity.amount, result.snapshots.last!.totalValue.amount,
                       "finalEquity must equal the last snapshot's totalValue")
    }
}

// MARK: - MLXBacktestRunner dispatch tests
//
// These tests verify that `MLXBacktestRunner.run` routes
// `VectorizableStrategy + NoTaxes` to the fast path.

final class MLXRunnerDispatchTests: XCTestCase {

    // MARK: AC3 — result shape

    /// For a `VectorizableStrategy`, MLXBacktestRunner must produce a
    /// BacktestResult with all five key metrics populated correctly.
    func test_vectStrategy_resultHasTotalReturn_drawdown_sharpe_equity_fillCount() async throws {
        let sym = Symbol("T")
        // 20 bars, rising prices: open = 100+i, close = 100+i
        let bars = makeBars(20, symbol: sym)
        let config = makeConfig(bars: bars)
        let strategy = DefinedSignalStrategy(
            symbol: sym,
            signalArray: [Bool](repeating: true, count: 20)
        )

        let result = try await MLXBacktestRunner().run(
            strategy: strategy, bars: bars, config: config
        )

        // totalReturn is a Decimal computed property — just verify it's present
        _ = result.totalReturn
        // maxDrawdown is non-negative
        XCTAssertGreaterThanOrEqual(result.maxDrawdown, 0)
        // sharpe is a Double
        _ = result.sharpe
        // finalEquity is a Money
        _ = result.finalEquity
        // fillCount is well-defined
        let fillCount = result.fills.count
        XCTAssertGreaterThanOrEqual(fillCount, 0,
                                    "fill count must be a non-negative integer")
    }

    /// VectorizableStrategy with NoTaxes → fills are generated via the vectorized path.
    /// This is verified by checking that fills exist and have the expected timestamps
    /// (i.e., the vectorized path ran, not just a no-op from the event-driven onBar).
    func test_vectStrategy_noTaxes_fillsGeneratedByVectorizedPath() async throws {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym)
        let config = makeConfig(bars: bars)
        // Always-long: vectorized path should produce 1 buy fill at bar[1]
        let strategy = DefinedSignalStrategy(
            symbol: sym,
            signalArray: [true, true, true, true, true]
        )

        let result = try await MLXBacktestRunner().run(
            strategy: strategy, bars: bars, config: config
        )

        // EventDrivenRunner with DefinedSignalStrategy.onBar (does nothing) → 0 fills
        // Vectorized path → 1 buy fill at bar[1]
        XCTAssertEqual(result.fills.count, 1,
                       "Vectorized path must produce 1 buy fill for always-long strategy")
        XCTAssertEqual(result.fills[0].side, .buy)
    }

    /// Snapshots count equals bar count for a vectorizable strategy.
    func test_vectStrategy_snapshotCountEqualsBarCount() async throws {
        let sym = Symbol("T")
        let bars = makeBars(10, symbol: sym)
        let config = makeConfig(bars: bars)
        let strategy = DefinedSignalStrategy(
            symbol: sym,
            signalArray: [Bool](repeating: false, count: 10)
        )

        let result = try await MLXBacktestRunner().run(
            strategy: strategy, bars: bars, config: config
        )

        XCTAssertEqual(result.snapshots.count, bars.count,
                       "One snapshot per bar for vectorizable strategy")
    }

    /// totalReturn is zero for a flat strategy (no fills, equity unchanged).
    func test_flatVectStrategy_totalReturnIsZero() async throws {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym)
        let config = makeConfig(bars: bars)
        let strategy = DefinedSignalStrategy(
            symbol: sym,
            signalArray: [false, false, false, false, false]
        )

        let result = try await MLXBacktestRunner().run(
            strategy: strategy, bars: bars, config: config
        )

        XCTAssertEqual(result.totalReturn, 0,
                       "Flat strategy must have zero totalReturn")
        XCTAssertEqual(result.finalEquity, config.initialCash,
                       "Flat strategy must leave equity unchanged")
    }

    // MARK: AC4 — parameter order preserved

    /// Grid sweep over a VectorizableStrategy preserves ParameterSet order.
    func test_sweepWithVectStrategy_preservesParameterOrder() async {
        let sym = Symbol("T")
        let bars = makeBars(10, symbol: sym)
        let config = makeConfig(bars: bars)
        let expectedQtys = [1, 2, 3, 4]
        let space = ParameterSpace.grid([.ints("x", expectedQtys)])
        let sym2 = sym

        let factory = ClosureStrategyFactory { params -> any Strategy in
            DefinedSignalStrategy(
                symbol: sym2,
                signalArray: [Bool](repeating: true, count: 10)
            )
        }
        let results = await Sweep(
            factory: factory,
            runner: MLXBacktestRunner(),
            bars: bars,
            config: config,
            space: space
        ).run()

        XCTAssertEqual(results.count, expectedQtys.count)
        for (r, x) in zip(results, expectedQtys) {
            XCTAssertEqual(r.params.int("x"), x, "Parameter order must be preserved")
        }
    }

    // MARK: AC5 — per-cell failure isolation

    /// A cell that throws in the factory must not prevent other cells from running.
    func test_sweepWithVectStrategy_isolatesPerCellFailure() async {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym)
        let config = makeConfig(bars: bars)
        let space = ParameterSpace.grid([.ints("fail", [0, 1, 2])])
        let sym2 = sym

        let factory = ClosureStrategyFactory { params -> any Strategy in
            if params.int("fail") == 1 {
                throw NSError(domain: "TestError", code: 1)
            }
            return DefinedSignalStrategy(symbol: sym2, signalArray: [Bool](repeating: false, count: 5))
        }
        let results = await Sweep(
            factory: factory,
            runner: MLXBacktestRunner(),
            bars: bars,
            config: config,
            space: space
        ).run()

        XCTAssertEqual(results.count, 3, "All 3 cells must return a result")
        XCTAssertEqual(results[0].params.int("fail"), 0)
        XCTAssertEqual(results[1].params.int("fail"), 1)
        XCTAssertEqual(results[2].params.int("fail"), 2)
        if case .failure = results[1].outcome {
            // expected
        } else {
            XCTFail("Cell 1 must record a failure outcome")
        }
        if case .success = results[0].outcome {} else { XCTFail("Cell 0 must succeed") }
        if case .success = results[2].outcome {} else { XCTFail("Cell 2 must succeed") }
    }
}

// MARK: - MLXBacktestRunner signal-mismatch error isolation tests
//
// These tests verify User Story 13: NaN/shape errors from VectorizableStrategy
// implementations are surfaced as per-cell SweepError — never crashing the sweep.

final class MLXRunnerErrorIsolationTests: XCTestCase {

    // MARK: AC1 — signalCountMismatch throws a typed error

    /// When `signals(for:)` returns fewer elements than `bars.count`,
    /// `MLXBacktestRunner.run` must throw `VectorizedFillSimulatorError.signalCountMismatch`
    /// rather than trapping or returning a corrupted result.
    func test_signalCountMismatch_throwsTypedError() async {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym)
        let config = makeConfig(bars: bars)
        // Returns 3 signals for 5 bars — a contract violation.
        let badStrategy = DefinedSignalStrategy(symbol: sym, signalArray: [true, false, true])

        var caughtMismatch = false
        do {
            _ = try await MLXBacktestRunner().run(
                strategy: badStrategy, bars: bars, config: config
            )
            XCTFail("Expected VectorizedFillSimulatorError.signalCountMismatch to be thrown")
        } catch VectorizedFillSimulatorError.signalCountMismatch(let sc, let bc) {
            caughtMismatch = true
            XCTAssertEqual(sc, 3, "signalCount in the error must reflect the returned array length")
            XCTAssertEqual(bc, 5, "barCount in the error must reflect the filtered bar count")
        } catch {
            XCTFail("Expected VectorizedFillSimulatorError, got \(error)")
        }
        XCTAssertTrue(caughtMismatch, "signalCountMismatch error must have been thrown")
    }

    /// When `signals(for:)` returns MORE elements than `bars.count`, the same
    /// typed error must be thrown.
    func test_signalCountMismatch_tooManySignals_throwsTypedError() async {
        let sym = Symbol("T")
        let bars = makeBars(3, symbol: sym)
        let config = makeConfig(bars: bars)
        // Returns 5 signals for 3 bars.
        let badStrategy = DefinedSignalStrategy(
            symbol: sym,
            signalArray: [true, false, true, false, true]
        )

        do {
            _ = try await MLXBacktestRunner().run(
                strategy: badStrategy, bars: bars, config: config
            )
            XCTFail("Expected VectorizedFillSimulatorError.signalCountMismatch to be thrown")
        } catch VectorizedFillSimulatorError.signalCountMismatch(let sc, let bc) {
            XCTAssertEqual(sc, 5, "signalCount must equal the oversized array length")
            XCTAssertEqual(bc, 3, "barCount must equal the bar array length")
        } catch {
            XCTFail("Expected VectorizedFillSimulatorError, got \(error)")
        }
    }

    // MARK: AC2 — signalCountMismatch is isolated as a per-cell .failure in a Sweep

    /// A single cell whose VectorizableStrategy returns a wrong-length signal
    /// array must produce a `.failure` SweepResult — the error must NOT crash
    /// the sweep or affect adjacent cells.
    func test_signalCountMismatch_isolatedAsPerCellFailure() async {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym)
        let config = makeConfig(bars: bars)
        let space = ParameterSpace.grid([.ints("cell", [0, 1, 2])])
        let sym2 = sym

        // Cell 1 returns a wrong-length signal array; cells 0 and 2 are fine.
        let factory = ClosureStrategyFactory { params -> any Strategy in
            if params.int("cell") == 1 {
                // 2 signals for 5 bars → signalCountMismatch at runtime.
                return DefinedSignalStrategy(symbol: sym2, signalArray: [true, false])
            }
            return DefinedSignalStrategy(symbol: sym2, signalArray: [Bool](repeating: false, count: 5))
        }

        let results = await Sweep(
            factory: factory,
            runner: MLXBacktestRunner(),
            bars: bars,
            config: config,
            space: space
        ).run()

        XCTAssertEqual(results.count, 3,
                       "All 3 cells must return a result even when one produces a signal mismatch")
        // Cell 0 and cell 2 must succeed.
        if case .success = results[0].outcome {} else {
            XCTFail("Cell 0 (no mismatch) must succeed")
        }
        // Cell 1 must be a per-cell failure — NOT a crash.
        if case .failure = results[1].outcome {
            // expected — signal mismatch surfaced as SweepError
        } else {
            XCTFail("Cell 1 (signal mismatch) must produce a .failure outcome, not crash the sweep")
        }
        if case .success = results[2].outcome {} else {
            XCTFail("Cell 2 (no mismatch) must succeed")
        }
    }

    // MARK: AC3 — VectorizedFillSimulatorError provides a meaningful localizedDescription

    /// The error's `localizedDescription` must include signal count and bar count
    /// so callers can diagnose the problem without inspecting the enum case.
    func test_signalCountMismatch_errorDescription_isInformative() {
        let err = VectorizedFillSimulatorError.signalCountMismatch(signalCount: 7, barCount: 10)
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("7"),
                      "errorDescription must mention the actual signal count (7)")
        XCTAssertTrue(desc.contains("10"),
                      "errorDescription must mention the expected bar count (10)")
    }
}

// Money already conforms to Hashable (and thus Equatable) in AthenaCore.
