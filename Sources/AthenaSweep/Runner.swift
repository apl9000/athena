import Foundation
import AthenaCore
import AthenaBacktest

// MARK: - StrategyFactory

/// Builds a fresh `Strategy` for a given `ParameterSet`. Implementations
/// should return a brand-new strategy instance per call — sharing
/// mutable state across runs of a sweep is undefined behavior.
public protocol StrategyFactory: Sendable {
    func make(_ params: ParameterSet) throws -> any Strategy
}

/// Closure-based factory for one-off use without a bespoke type.
public struct ClosureStrategyFactory: StrategyFactory {
    public let body: @Sendable (ParameterSet) throws -> any Strategy
    public init(_ body: @escaping @Sendable (ParameterSet) throws -> any Strategy) {
        self.body = body
    }
    public func make(_ params: ParameterSet) throws -> any Strategy {
        try body(params)
    }
}

// MARK: - BacktestRunner

/// Abstraction over "run one strategy over one set of bars and return a
/// `BacktestResult`". The v0.4 default impl wraps `BacktestEngine`. The
/// v0.5 MLX vectorized engine will plug in here as a second
/// implementation that can score many `ParameterSet`s in a single GPU
/// dispatch.
public protocol BacktestRunner: Sendable {
    func run(
        strategy: any Strategy,
        bars: [Bar],
        config: BacktestConfig
    ) async throws -> BacktestResult
}

/// Default `BacktestRunner` — runs the existing event-driven
/// `BacktestEngine`. One instance is reusable across many runs because
/// each call builds a fresh `BacktestEngine` actor under the hood.
public struct EventDrivenRunner: BacktestRunner {
    public init() {}

    public func run(
        strategy: any Strategy,
        bars: [Bar],
        config: BacktestConfig
    ) async throws -> BacktestResult {
        let engine = BacktestEngine(config: config, strategy: strategy, bars: bars)
        return try await engine.run()
    }
}
