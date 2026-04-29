import Foundation

/// Strategies access indicators through this interface. The concrete implementation
/// lives in `AthenaIndicators`; `AthenaCore` only needs the contract so that
/// `Strategy` and `StrategyContext` can compile without depending on the
/// indicators module.
///
/// Adding a new indicator accessor here is a public API change and should be
/// treated as such under semver.
public protocol IndicatorProvider: Sendable {
    func sma(_ symbol: Symbol, period: Int) async -> Decimal?
    func ema(_ symbol: Symbol, period: Int) async -> Decimal?
    func rsi(_ symbol: Symbol, period: Int) async -> Decimal?

    /// MACD returns (macd, signal, histogram). Default periods 12/26/9.
    func macd(
        _ symbol: Symbol,
        fast: Int,
        slow: Int,
        signal: Int
    ) async -> (macd: Decimal, signal: Decimal, histogram: Decimal)?

    /// Bollinger Bands returns (upper, middle, lower).
    func bollinger(
        _ symbol: Symbol,
        period: Int,
        stddev: Decimal
    ) async -> (upper: Decimal, middle: Decimal, lower: Decimal)?

    /// Average True Range.
    func atr(_ symbol: Symbol, period: Int) async -> Decimal?
}

public extension IndicatorProvider {
    func macd(_ symbol: Symbol) async -> (macd: Decimal, signal: Decimal, histogram: Decimal)? {
        await macd(symbol, fast: 12, slow: 26, signal: 9)
    }

    func bollinger(_ symbol: Symbol) async -> (upper: Decimal, middle: Decimal, lower: Decimal)? {
        await bollinger(symbol, period: 20, stddev: 2)
    }

    func atr(_ symbol: Symbol) async -> Decimal? {
        await atr(symbol, period: 14)
    }
}
