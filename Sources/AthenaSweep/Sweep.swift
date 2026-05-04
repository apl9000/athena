import Foundation
import AthenaCore
import AthenaBacktest

// MARK: - SweepResult

/// Outcome of one cell in a sweep. The sweep does not abort on
/// per-cell failures; downstream callers can filter `.failure` cases.
public struct SweepResult: Sendable {
    public let params: ParameterSet
    public let outcome: Outcome

    public enum Outcome: Sendable {
        case success(BacktestResult)
        case failure(SweepError)
    }

    public var backtest: BacktestResult? {
        if case .success(let r) = outcome { return r }
        return nil
    }
}

/// Per-cell error. `Sweep.run` never throws on cell failures — they
/// land here so a bad parameter combination can't poison a 100-point
/// grid run.
public struct SweepError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Sweep

/// Runs many backtests in parallel across a `ParameterSpace`.
///
/// One backtest is dispatched per `ParameterSet` in `space.sets`.
/// Concurrency is bounded by `concurrency` (default
/// `ProcessInfo.activeProcessorCount`) so big grids don't spawn
/// thousands of in-flight runs and thrash memory.
///
/// Order of the returned `[SweepResult]` matches `space.sets`.
public struct Sweep: Sendable {
    public let factory: any StrategyFactory
    public let runner: any BacktestRunner
    public let bars: [Bar]
    public let config: BacktestConfig
    public let space: ParameterSpace
    public let concurrency: Int

    public init(
        factory: any StrategyFactory,
        runner: any BacktestRunner = EventDrivenRunner(),
        bars: [Bar],
        config: BacktestConfig,
        space: ParameterSpace,
        concurrency: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.factory = factory
        self.runner = runner
        self.bars = bars
        self.config = config
        self.space = space
        self.concurrency = max(1, concurrency)
    }

    public func run() async -> [SweepResult] {
        let sets = space.sets
        guard !sets.isEmpty else { return [] }

        let factory = self.factory
        let runner = self.runner
        let bars = self.bars
        let config = self.config
        let limit = min(concurrency, sets.count)

        return await withTaskGroup(
            of: (Int, SweepResult).self,
            returning: [SweepResult].self
        ) { group in
            var nextIndex = 0

            // Prime the group up to the concurrency limit.
            for _ in 0..<limit {
                let i = nextIndex
                nextIndex += 1
                let p = sets[i]
                group.addTask {
                    (i, await Self.runOne(
                        factory: factory, runner: runner,
                        bars: bars, config: config, params: p
                    ))
                }
            }

            // As each task completes, dispatch the next pending cell.
            var collected: [(Int, SweepResult)] = []
            collected.reserveCapacity(sets.count)
            while let done = await group.next() {
                collected.append(done)
                if nextIndex < sets.count {
                    let i = nextIndex
                    nextIndex += 1
                    let p = sets[i]
                    group.addTask {
                        (i, await Self.runOne(
                            factory: factory, runner: runner,
                            bars: bars, config: config, params: p
                        ))
                    }
                }
            }

            collected.sort { $0.0 < $1.0 }
            return collected.map { $0.1 }
        }
    }

    private static func runOne(
        factory: any StrategyFactory,
        runner: any BacktestRunner,
        bars: [Bar],
        config: BacktestConfig,
        params: ParameterSet
    ) async -> SweepResult {
        do {
            let strategy = try factory.make(params)
            let result = try await runner.run(
                strategy: strategy, bars: bars, config: config
            )
            return SweepResult(params: params, outcome: .success(result))
        } catch {
            return SweepResult(
                params: params,
                outcome: .failure(SweepError(String(describing: error)))
            )
        }
    }
}
