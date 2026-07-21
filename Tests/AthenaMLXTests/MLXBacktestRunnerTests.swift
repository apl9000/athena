import XCTest
import AthenaCore
import AthenaBacktest
import AthenaSweep
@testable import AthenaMLX

// MARK: - Private fixtures

/// A strategy that does nothing — holds all cash through the run.
private struct NopStrategy: Strategy {
    func onBar(_ bar: Bar, context: StrategyContext) async throws {}
}

/// An actor-based once-flag so `BuyOnceStrategy` stays `Sendable`.
private actor _OnceFlag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// A strategy that buys `qty` shares on the first matching bar and holds.
private struct BuyOnceStrategy: Strategy {
    let symbol: Symbol
    let qty: Decimal
    private let flag = _OnceFlag()

    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }
        if await flag.isSet { return }
        await flag.set()
        _ = try? await context.buy(symbol, quantity: qty)
    }
}

/// A minimal `VectorizableStrategy` that is always long.
private struct AlwaysLongStrategy: Strategy, VectorizableStrategy {
    let symbol: Symbol
    func onBar(_ bar: Bar, context: StrategyContext) async throws {}
    func signals(for bars: [Bar]) -> [Bool] { bars.map { _ in true } }
}

/// A minimal `VectorizableStrategy` that is always flat.
private struct AlwaysFlatStrategy: Strategy, VectorizableStrategy {
    let symbol: Symbol
    func onBar(_ bar: Bar, context: StrategyContext) async throws {}
    func signals(for bars: [Bar]) -> [Bool] { bars.map { _ in false } }
}

// MARK: - Helpers

private func makeBars(
    _ n: Int,
    symbol: Symbol = Symbol("T"),
    startYear: Int = 2024
) -> [Bar] {
    let start = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: startYear, month: 1, day: 1))!
    return (0..<n).map { i in
        let price = Decimal(100 + i)
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

private func makeConfig(bars: [Bar]) -> BacktestConfig {
    BacktestConfig(
        startDate: bars.first!.timestamp,
        endDate: bars.last!.timestamp,
        initialCash: .usd(10_000)
    )
}

// MARK: - Protocol-conformance tests

final class MLXRunnerConformanceTests: XCTestCase {

    /// `MLXBacktestRunner` can be assigned to `any BacktestRunner`.
    /// This verifies the seam contract is fully satisfied.
    func test_mlxRunner_conformsToBacktestRunnerProtocol() {
        let runner: any BacktestRunner = MLXBacktestRunner()
        XCTAssertNotNil(runner)
    }

    /// `MLXBacktestRunner` can be passed to `Sweep.init(runner:)`.
    func test_mlxRunner_canBeUsedAsSweepRunner() async {
        let sym = Symbol("T")
        let bars = makeBars(5, symbol: sym)
        let config = makeConfig(bars: bars)
        let space = ParameterSpace.grid([.ints("qty", [1])])
        let sym2 = sym  // capture for @Sendable closure
        let factory = ClosureStrategyFactory { params -> any Strategy in
            BuyOnceStrategy(symbol: sym2, qty: Decimal(params.int("qty") ?? 1))
        }
        let sweep = Sweep(
            factory: factory,
            runner: MLXBacktestRunner(),
            bars: bars,
            config: config,
            space: space
        )
        let results = await sweep.run()
        XCTAssertEqual(results.count, 1,
                       "Sweep with MLXRunner should return one result per parameter set")
    }

    /// `MLXBacktestRunner()` initialises without parameters.
    func test_mlxRunner_hasPublicZeroArgInit() {
        _ = MLXBacktestRunner()  // must compile and not trap
    }
}

// MARK: - Single-cell execution tests

final class MLXRunnerSingleCellTests: XCTestCase {

    /// A bare `run(strategy:bars:config:)` call returns a valid result.
    func test_singleRun_returnsBacktestResult() async throws {
        let bars = makeBars(5)
        let config = makeConfig(bars: bars)
        let result = try await MLXBacktestRunner().run(
            strategy: NopStrategy(),
            bars: bars,
            config: config
        )
        XCTAssertNotNil(result)
    }

    /// The result's initial equity matches the config's `initialCash`.
    func test_singleRun_resultHasCorrectInitialEquity() async throws {
        let bars = makeBars(5)
        let config = makeConfig(bars: bars)
        let result = try await MLXBacktestRunner().run(
            strategy: NopStrategy(),
            bars: bars,
            config: config
        )
        XCTAssertEqual(result.initialEquity, config.initialCash,
                       "Initial equity must match the config's initialCash")
    }

    /// Running with empty bars returns a result without crashing.
    func test_singleRun_handlesEmptyBars() async throws {
        let config = BacktestConfig(
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 86_400),
            initialCash: .usd(10_000)
        )
        let result = try await MLXBacktestRunner().run(
            strategy: NopStrategy(),
            bars: [],
            config: config
        )
        XCTAssertNotNil(result)
    }
}

// MARK: - Result-shape equivalence tests

final class MLXRunnerResultShapeTests: XCTestCase {

    /// Result count from `MLXBacktestRunner` matches `EventDrivenRunner` on
    /// a grid sweep.
    func test_gridSweep_mlxAndEventDrivenReturnSameCount() async {
        let sym = Symbol("T")
        let bars = makeBars(10, symbol: sym)
        let config = makeConfig(bars: bars)
        let space = ParameterSpace.grid([.ints("qty", [1, 5, 10])])
        let sym2 = sym
        let factory = ClosureStrategyFactory { params -> any Strategy in
            BuyOnceStrategy(symbol: sym2, qty: Decimal(params.int("qty") ?? 1))
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
                       "Both runners must return one SweepResult per parameter set")
    }

    /// Parameter-set order is preserved through `MLXBacktestRunner`.
    func test_gridSweep_mlxRunnerPreservesParameterOrder() async {
        let sym = Symbol("T")
        let bars = makeBars(10, symbol: sym)
        let config = makeConfig(bars: bars)
        let expectedQtys = [1, 2, 3]
        let space = ParameterSpace.grid([.ints("qty", expectedQtys)])
        let sym2 = sym
        let factory = ClosureStrategyFactory { params -> any Strategy in
            BuyOnceStrategy(symbol: sym2, qty: Decimal(params.int("qty") ?? 1))
        }
        let results = await Sweep(
            factory: factory, runner: MLXBacktestRunner(),
            bars: bars, config: config, space: space
        ).run()

        XCTAssertEqual(results.count, expectedQtys.count)
        for (result, qty) in zip(results, expectedQtys) {
            XCTAssertEqual(result.params.int("qty"), qty,
                           "MLXBacktestRunner must preserve the parameter grid order")
        }
    }

    /// A per-cell failure does not crash the sweep.
    func test_gridSweep_mlxRunnerIsolatesPerCellFailure() async {
        let sym = Symbol("T")
        let bars = makeBars(3, symbol: sym)
        let config = makeConfig(bars: bars)
        let space = ParameterSpace.grid([.ints("x", [0])])
        // Factory always throws — simulates a bad parameter combination.
        let factory = ClosureStrategyFactory { _ -> any Strategy in
            throw NSError(domain: "TestError", code: 42)
        }
        let results = await Sweep(
            factory: factory, runner: MLXBacktestRunner(),
            bars: bars, config: config, space: space
        ).run()

        XCTAssertEqual(results.count, 1,
                       "One result per parameter set even on failure")
        if case .failure = results[0].outcome {
            // expected — per-cell failure is isolated
        } else {
            XCTFail("Expected a .failure outcome for a throwing factory")
        }
    }
}

// MARK: - VectorizableStrategy tests

final class VectorizableStrategyTests: XCTestCase {

    /// A type conforming to `VectorizableStrategy` also satisfies `Strategy`.
    func test_vectorizableStrategy_conformingTypeAlsoConformsToStrategy() {
        let strategy: any Strategy = AlwaysLongStrategy(symbol: Symbol("T"))
        XCTAssertNotNil(strategy)
    }

    /// A `VectorizableStrategy` can be stored as `any VectorizableStrategy`.
    func test_vectorizableStrategy_canBeStoredAsProtocolExistential() {
        let strategy: any VectorizableStrategy = AlwaysLongStrategy(symbol: Symbol("T"))
        XCTAssertNotNil(strategy)
    }

    /// `signals(for:)` returns an array of the same length as the bar input.
    func test_vectorizableStrategy_signalCountMatchesBarCount() {
        let bars = makeBars(20)
        let strategy = AlwaysLongStrategy(symbol: Symbol("T"))
        XCTAssertEqual(strategy.signals(for: bars).count, bars.count,
                       "Signal array must have the same length as the bar array")
    }

    /// `signals(for:)` returns an empty array when given empty input.
    func test_vectorizableStrategy_emptyBarsProduceEmptySignals() {
        let strategy = AlwaysLongStrategy(symbol: Symbol("T"))
        XCTAssertTrue(strategy.signals(for: []).isEmpty,
                      "Empty bars must produce an empty signal array")
    }

    /// An always-flat strategy produces all-false signals.
    func test_vectorizableStrategy_flatStrategyProducesAllFalseSignals() {
        let bars = makeBars(5)
        let strategy = AlwaysFlatStrategy(symbol: Symbol("T"))
        XCTAssertTrue(strategy.signals(for: bars).allSatisfy { !$0 },
                      "AlwaysFlatStrategy must produce all-false signals")
    }

    /// An always-long strategy produces all-true signals.
    func test_vectorizableStrategy_longStrategyProducesAllTrueSignals() {
        let bars = makeBars(5)
        let strategy = AlwaysLongStrategy(symbol: Symbol("T"))
        XCTAssertTrue(strategy.signals(for: bars).allSatisfy { $0 },
                      "AlwaysLongStrategy must produce all-true signals")
    }
}
