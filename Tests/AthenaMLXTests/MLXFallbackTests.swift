import XCTest
import AthenaCore
import AthenaBacktest
import AthenaSweep
@testable import AthenaMLX

// MARK: - Documented tolerance

/// Maximum acceptable difference when comparing `Sharpe` (a `Double`) between
/// two runners. Both paths delegate to `EventDrivenRunner` in the current
/// slice, so results are bit-identical; the tolerance documents the acceptable
/// bound for future tensor-dispatch implementations.
///
/// NOTE: Once real MLX tensor dispatch is active, accumulated Float16/Float32
/// rounding will likely require relaxing this constant (suggested: 1e-6).
private let kSharpeMatchTolerance: Double = 1e-12

// MARK: - Sendable actor flag

/// Sendable once-flag backed by an actor so stateful strategy structs can
/// satisfy Swift Concurrency's `Sendable` requirement.
private actor _PurchaseFlag {
    private(set) var didBuy = false
    func markBought() { didBuy = true }
}

// MARK: - Private test fixtures

/// A strategy that does **NOT** conform to `VectorizableStrategy`.
/// It buys `qty` shares on the first bar it sees and holds.
/// Its absence of `VectorizableStrategy` conformance guarantees that
/// `MLXBacktestRunner` will route it through the fallback path.
private struct NonVectorizableStrategy: Strategy {
    let symbol: Symbol
    let qty: Decimal
    private let flag = _PurchaseFlag()

    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }
        guard await !flag.didBuy else { return }
        await flag.markBought()
        _ = try? await context.buy(symbol, quantity: qty)
    }
}

/// A strategy that **does** conform to `VectorizableStrategy` and also
/// buys on the first bar via `onBar`. Used with a non-`NoTaxes` regime
/// so the tax-regime check, not the strategy check, forces the fallback.
private struct VectorizableBuyFirstBarStrategy: Strategy, VectorizableStrategy {
    let symbol: Symbol
    let qty: Decimal
    private let flag = _PurchaseFlag()

    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }
        guard await !flag.didBuy else { return }
        await flag.markBought()
        _ = try? await context.buy(symbol, quantity: qty)
    }

    /// Signal: flat on bar 0, long from bar 1 onward.
    ///
    /// The `false → true` transition at index 0→1 triggers a buy at bar 1's
    /// open (per the `VectorizableStrategy` contract: "a change triggers a fill
    /// at the **next** bar's open"). This matches `onBar` semantics above, which
    /// places an order on bar 0 that fills at bar 1's open.
    func signals(for bars: [Bar]) -> [Bool] {
        bars.enumerated().map { (i, _) in i > 0 }
    }
}

// MARK: - Bar and config helpers

private func makeLinearBars(
    _ n: Int,
    symbol: Symbol = Symbol("T"),
    startPrice: Int = 100,
    year: Int = 2024
) -> [Bar] {
    let start = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: year, month: 1, day: 1))!
    return (0..<n).map { i in
        let price = Decimal(startPrice + i)
        return Bar(
            symbol: symbol,
            timestamp: start.addingTimeInterval(Double(i) * 86_400),
            open: price,
            high: price + 1,
            low: price - 1,
            close: price,
            volume: 1_000_000
        )
    }
}

private func makeConfig(
    bars: [Bar],
    taxRegime: any TaxRegime = NoTaxes()
) -> BacktestConfig {
    BacktestConfig(
        startDate: bars.first!.timestamp,
        endDate: bars.last!.timestamp,
        initialCash: .usd(50_000),
        taxRegime: taxRegime
    )
}

// MARK: - Non-VectorizableStrategy fallback tests

/// Verifies that strategies not conforming to `VectorizableStrategy` are
/// transparently routed to `EventDrivenRunner` by `MLXBacktestRunner`, and
/// that all five observable metrics are numerically identical to a direct
/// `EventDrivenRunner` run on the same strategy and bars.
///
/// These tests run on all platforms (no MLX required — the fallback is
/// active everywhere) and remain valid after real MLX tensor dispatch is
/// added in later slices.
final class MLXFallbackNonVectorizableTests: XCTestCase {

    /// Total return must be identical when a non-VectorizableStrategy
    /// falls back to `EventDrivenRunner`.
    func test_nonVectorizableStrategy_totalReturnMatchesEventDrivenRunner() async throws {
        let sym = Symbol("T")
        let bars = makeLinearBars(120, symbol: sym)
        let config = makeConfig(bars: bars)

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: NonVectorizableStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: NonVectorizableStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.totalReturn, edResult.totalReturn,
            "totalReturn must be identical: non-VectorizableStrategy falls back to EventDrivenRunner"
        )
    }

    /// Max drawdown must be identical when a non-VectorizableStrategy
    /// falls back to `EventDrivenRunner`.
    func test_nonVectorizableStrategy_maxDrawdownMatchesEventDrivenRunner() async throws {
        let sym = Symbol("T")
        let bars = makeLinearBars(120, symbol: sym)
        let config = makeConfig(bars: bars)

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: NonVectorizableStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: NonVectorizableStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.maxDrawdown, edResult.maxDrawdown,
            "maxDrawdown must be identical: non-VectorizableStrategy falls back to EventDrivenRunner"
        )
    }

    /// Annualised Sharpe must match within `kSharpeMatchTolerance` when a
    /// non-VectorizableStrategy falls back to `EventDrivenRunner`.
    func test_nonVectorizableStrategy_sharpeMatchesEventDrivenRunner() async throws {
        let sym = Symbol("T")
        let bars = makeLinearBars(120, symbol: sym)
        let config = makeConfig(bars: bars)

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: NonVectorizableStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: NonVectorizableStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.sharpe, edResult.sharpe,
            accuracy: kSharpeMatchTolerance,
            "Sharpe must match within \(kSharpeMatchTolerance): non-VectorizableStrategy falls back to EventDrivenRunner"
        )
    }

    /// Final equity must be identical when a non-VectorizableStrategy
    /// falls back to `EventDrivenRunner`.
    func test_nonVectorizableStrategy_finalEquityMatchesEventDrivenRunner() async throws {
        let sym = Symbol("T")
        let bars = makeLinearBars(120, symbol: sym)
        let config = makeConfig(bars: bars)

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: NonVectorizableStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: NonVectorizableStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.finalEquity, edResult.finalEquity,
            "finalEquity must be identical: non-VectorizableStrategy falls back to EventDrivenRunner"
        )
    }

    /// Fill count must be identical when a non-VectorizableStrategy
    /// falls back to `EventDrivenRunner`.
    func test_nonVectorizableStrategy_fillCountMatchesEventDrivenRunner() async throws {
        let sym = Symbol("T")
        let bars = makeLinearBars(120, symbol: sym)
        let config = makeConfig(bars: bars)

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: NonVectorizableStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: NonVectorizableStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.fills.count, edResult.fills.count,
            "fill count must be identical: non-VectorizableStrategy falls back to EventDrivenRunner"
        )
        XCTAssertGreaterThan(
            mlxResult.fills.count, 0,
            "Fixture must produce at least one fill so the count comparison is non-trivial"
        )
    }
}

// MARK: - Non-NoTaxes tax-regime fallback tests

/// Verifies that any `BacktestConfig` whose `taxRegime` is not `NoTaxes`
/// forces `MLXBacktestRunner` to fall back to `EventDrivenRunner` per cell —
/// even when the strategy conforms to `VectorizableStrategy`. The five
/// observable metrics must be numerically identical to a direct
/// `EventDrivenRunner` run with the same config.
///
/// These tests run on all platforms and remain valid after real MLX tensor
/// dispatch is added in later slices (the fast path is restricted to
/// `NoTaxes` configs only).
final class MLXFallbackTaxRegimeTests: XCTestCase {

    /// Total return must match when a VectorizableStrategy with USWashSale
    /// falls back to `EventDrivenRunner`.
    func test_usWashSaleRegime_totalReturnMatchesEventDrivenRunner() async throws {
        let sym = Symbol("T")
        let bars = makeLinearBars(120, symbol: sym)
        let config = makeConfig(bars: bars, taxRegime: USWashSale())

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.totalReturn, edResult.totalReturn,
            "totalReturn must match: USWashSale regime forces fallback to EventDrivenRunner"
        )
    }

    /// Max drawdown must match when a VectorizableStrategy with USWashSale
    /// falls back to `EventDrivenRunner`.
    func test_usWashSaleRegime_maxDrawdownMatchesEventDrivenRunner() async throws {
        let sym = Symbol("T")
        let bars = makeLinearBars(120, symbol: sym)
        let config = makeConfig(bars: bars, taxRegime: USWashSale())

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.maxDrawdown, edResult.maxDrawdown,
            "maxDrawdown must match: USWashSale regime forces fallback to EventDrivenRunner"
        )
    }

    /// Final equity must match when a VectorizableStrategy with USWashSale
    /// falls back to `EventDrivenRunner`.
    func test_usWashSaleRegime_finalEquityMatchesEventDrivenRunner() async throws {
        let sym = Symbol("T")
        let bars = makeLinearBars(120, symbol: sym)
        let config = makeConfig(bars: bars, taxRegime: USWashSale())

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.finalEquity, edResult.finalEquity,
            "finalEquity must match: USWashSale regime forces fallback to EventDrivenRunner"
        )
    }

    /// Fill count must match when a VectorizableStrategy with USWashSale
    /// falls back to `EventDrivenRunner`.
    func test_usWashSaleRegime_fillCountMatchesEventDrivenRunner() async throws {
        let sym = Symbol("T")
        let bars = makeLinearBars(120, symbol: sym)
        let config = makeConfig(bars: bars, taxRegime: USWashSale())

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.fills.count, edResult.fills.count,
            "fill count must match: USWashSale regime forces fallback to EventDrivenRunner"
        )
        XCTAssertGreaterThan(
            mlxResult.fills.count, 0,
            "Fixture must produce at least one fill so the count comparison is non-trivial"
        )
    }

    /// Sharpe must match when a VectorizableStrategy with USWashSale
    /// falls back to `EventDrivenRunner`.
    func test_usWashSaleRegime_sharpeMatchesEventDrivenRunner() async throws {
        let sym = Symbol("T")
        let bars = makeLinearBars(120, symbol: sym)
        let config = makeConfig(bars: bars, taxRegime: USWashSale())

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 10),
            bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.sharpe, edResult.sharpe,
            accuracy: kSharpeMatchTolerance,
            "Sharpe must match: USWashSale regime forces fallback to EventDrivenRunner"
        )
    }

    /// `CanadianACB` regime must also force the fallback path, with results
    /// matching `EventDrivenRunner` directly.
    func test_canadianACBRegime_finalEquityMatchesEventDrivenRunner() async throws {
        let sym = Symbol("T")
        let bars = makeLinearBars(80, symbol: sym)
        let config = makeConfig(bars: bars, taxRegime: CanadianACB())

        let mlxResult = try await MLXBacktestRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 5),
            bars: bars, config: config
        )
        let edResult = try await EventDrivenRunner().run(
            strategy: VectorizableBuyFirstBarStrategy(symbol: sym, qty: 5),
            bars: bars, config: config
        )

        XCTAssertEqual(
            mlxResult.finalEquity, edResult.finalEquity,
            "CanadianACB must also force fallback to EventDrivenRunner"
        )
    }
}

// MARK: - Sweep-level fallback ordering and isolation

/// Verifies that `SweepResult` ordering is preserved and per-cell failures
/// are isolated in both fallback scenarios: non-VectorizableStrategy and
/// non-NoTaxes regime.
///
/// These tests exercise the sweep plumbing in fallback mode and are
/// platform-agnostic — no MLX availability required.
final class MLXFallbackSweepTests: XCTestCase {

    /// A grid sweep whose factory produces `NonVectorizableStrategy` cells
    /// must return results in parameter-grid order.
    func test_nonVectorizableSweep_preservesParameterOrder() async {
        let sym = Symbol("T")
        let bars = makeLinearBars(40, symbol: sym)
        let config = makeConfig(bars: bars)
        let expectedQtys = [1, 5, 10, 20]
        let space = ParameterSpace.grid([.ints("qty", expectedQtys)])
        let sym2 = sym
        let factory = ClosureStrategyFactory { params -> any Strategy in
            NonVectorizableStrategy(symbol: sym2, qty: Decimal(params.int("qty") ?? 1))
        }

        let results = await Sweep(
            factory: factory,
            runner: MLXBacktestRunner(),
            bars: bars, config: config, space: space
        ).run()

        XCTAssertEqual(results.count, expectedQtys.count,
                       "One result per parameter set")
        for (result, qty) in zip(results, expectedQtys) {
            XCTAssertEqual(
                result.params.int("qty"), qty,
                "Non-VectorizableStrategy fallback sweep must preserve parameter grid order"
            )
        }
    }

    /// A grid sweep that forces tax-regime fallback (VectorizableStrategy
    /// with USWashSale config) must return results in parameter-grid order.
    func test_nonNoTaxesSweep_preservesParameterOrder() async {
        let sym = Symbol("T")
        let bars = makeLinearBars(40, symbol: sym)
        let config = makeConfig(bars: bars, taxRegime: USWashSale())
        let expectedQtys = [1, 5, 10]
        let space = ParameterSpace.grid([.ints("qty", expectedQtys)])
        let sym2 = sym
        let factory = ClosureStrategyFactory { params -> any Strategy in
            // VectorizableBuyFirstBarStrategy conforms to VectorizableStrategy;
            // the USWashSale regime forces the fallback path.
            VectorizableBuyFirstBarStrategy(symbol: sym2, qty: Decimal(params.int("qty") ?? 1))
        }

        let results = await Sweep(
            factory: factory,
            runner: MLXBacktestRunner(),
            bars: bars, config: config, space: space
        ).run()

        XCTAssertEqual(results.count, expectedQtys.count,
                       "One result per parameter set")
        for (result, qty) in zip(results, expectedQtys) {
            XCTAssertEqual(
                result.params.int("qty"), qty,
                "Tax-regime fallback sweep must preserve parameter grid order"
            )
        }
    }

    /// A failing cell in a non-VectorizableStrategy sweep must not poison
    /// adjacent cells. The failing cell produces `.failure`; the other cells
    /// produce `.success`.
    func test_nonVectorizableSweep_isolatesPerCellFailures() async {
        let sym = Symbol("T")
        let bars = makeLinearBars(10, symbol: sym)
        let config = makeConfig(bars: bars)
        // Three cells: first succeeds, second fails at factory, third succeeds.
        let space = ParameterSpace.grid([.ints("x", [1, -1, 2])])
        let sym2 = sym
        let factory = ClosureStrategyFactory { params -> any Strategy in
            let x = params.int("x") ?? 0
            guard x > 0 else {
                throw NSError(domain: "TestFallbackError", code: x,
                              userInfo: [NSLocalizedDescriptionKey: "invalid parameter x=\(x)"])
            }
            return NonVectorizableStrategy(symbol: sym2, qty: Decimal(x))
        }

        let results = await Sweep(
            factory: factory,
            runner: MLXBacktestRunner(),
            bars: bars, config: config, space: space
        ).run()

        XCTAssertEqual(results.count, 3,
                       "All three cells must be reported even when one fails")
        if case .success = results[0].outcome { /* expected */ }
        else { XCTFail("Cell 0 (x=1) must succeed in non-VectorizableStrategy fallback") }
        if case .failure = results[1].outcome { /* expected */ }
        else { XCTFail("Cell 1 (x=-1) must fail with an isolated error") }
        if case .success = results[2].outcome { /* expected */ }
        else { XCTFail("Cell 2 (x=2) must succeed in non-VectorizableStrategy fallback") }
    }

    /// A failing cell in a tax-regime fallback sweep must not poison
    /// adjacent cells.
    func test_taxRegimeSweep_isolatesPerCellFailures() async {
        let sym = Symbol("T")
        let bars = makeLinearBars(10, symbol: sym)
        let config = makeConfig(bars: bars, taxRegime: USWashSale())
        let space = ParameterSpace.grid([.ints("x", [1, -1, 2])])
        let sym2 = sym
        let factory = ClosureStrategyFactory { params -> any Strategy in
            let x = params.int("x") ?? 0
            guard x > 0 else {
                throw NSError(domain: "TestFallbackError", code: x,
                              userInfo: [NSLocalizedDescriptionKey: "invalid parameter x=\(x)"])
            }
            return VectorizableBuyFirstBarStrategy(symbol: sym2, qty: Decimal(x))
        }

        let results = await Sweep(
            factory: factory,
            runner: MLXBacktestRunner(),
            bars: bars, config: config, space: space
        ).run()

        XCTAssertEqual(results.count, 3,
                       "All three cells must be reported even when one fails")
        if case .success = results[0].outcome { /* expected */ }
        else { XCTFail("Cell 0 (x=1) must succeed in tax-regime fallback") }
        if case .failure = results[1].outcome { /* expected */ }
        else { XCTFail("Cell 1 (x=-1) must fail with an isolated error") }
        if case .success = results[2].outcome { /* expected */ }
        else { XCTFail("Cell 2 (x=2) must succeed in tax-regime fallback") }
    }
}
