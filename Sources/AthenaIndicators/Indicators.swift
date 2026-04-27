import Foundation
import AthenaCore

// MARK: - Indicator protocol

/// Incremental indicator. Fed one bar at a time; holds state; emits current value.
/// This is the event-driven shape. The vectorized counterpart (Phase 2) will be a
/// separate protocol for whole-series computation.
public protocol Indicator: Sendable {
    associatedtype Value: Sendable
    mutating func update(_ bar: Bar) -> Value?
    var current: Value? { get }
}

// MARK: - Indicator cache (concrete implementation of IndicatorProvider)

public actor IndicatorCache: IndicatorProvider {
    private struct Key: Hashable {
        let symbol: Symbol
        let period: Int
    }

    private struct MACDKey: Hashable {
        let symbol: Symbol
        let fast: Int
        let slow: Int
        let signal: Int
    }

    private struct BBKey: Hashable {
        let symbol: Symbol
        let period: Int
        let stddev: Decimal
    }

    private var smaCache: [Key: SMA] = [:]
    private var emaCache: [Key: EMA] = [:]
    private var rsiCache: [Key: RSI] = [:]
    private var macdCache: [MACDKey: MACD] = [:]
    private var bbCache: [BBKey: BollingerBands] = [:]
    private var atrCache: [Key: ATR] = [:]

    public init() {}

    /// Called by the engine on every bar before the strategy runs.
    /// v0.1 caveat: indicators created mid-run by the strategy on bar N will be fed
    /// starting bar N+1, so there is a one-bar warmup delay. In practice SMA(50)
    /// needs 50 bars anyway; the one-bar shift is immaterial. Pre-register in
    /// `onStart` if you need bit-for-bit alignment with Python reference outputs.
    public func update(with bar: Bar) {
        for (k, var ind) in smaCache where k.symbol == bar.symbol {
            _ = ind.update(bar); smaCache[k] = ind
        }
        for (k, var ind) in emaCache where k.symbol == bar.symbol {
            _ = ind.update(bar); emaCache[k] = ind
        }
        for (k, var ind) in rsiCache where k.symbol == bar.symbol {
            _ = ind.update(bar); rsiCache[k] = ind
        }
        for (k, var ind) in macdCache where k.symbol == bar.symbol {
            _ = ind.update(bar); macdCache[k] = ind
        }
        for (k, var ind) in bbCache where k.symbol == bar.symbol {
            _ = ind.update(bar); bbCache[k] = ind
        }
        for (k, var ind) in atrCache where k.symbol == bar.symbol {
            _ = ind.update(bar); atrCache[k] = ind
        }
    }

    public func sma(_ symbol: Symbol, period: Int) -> Decimal? {
        let key = Key(symbol: symbol, period: period)
        if smaCache[key] == nil { smaCache[key] = SMA(period: period) }
        return smaCache[key]?.current
    }

    public func ema(_ symbol: Symbol, period: Int) -> Decimal? {
        let key = Key(symbol: symbol, period: period)
        if emaCache[key] == nil { emaCache[key] = EMA(period: period) }
        return emaCache[key]?.current
    }

    public func rsi(_ symbol: Symbol, period: Int = 14) -> Decimal? {
        let key = Key(symbol: symbol, period: period)
        if rsiCache[key] == nil { rsiCache[key] = RSI(period: period) }
        return rsiCache[key]?.current
    }

    public func macd(
        _ symbol: Symbol,
        fast: Int = 12,
        slow: Int = 26,
        signal: Int = 9
    ) -> (macd: Decimal, signal: Decimal, histogram: Decimal)? {
        let key = MACDKey(symbol: symbol, fast: fast, slow: slow, signal: signal)
        if macdCache[key] == nil {
            macdCache[key] = MACD(fast: fast, slow: slow, signal: signal)
        }
        return macdCache[key]?.current
    }

    public func bollinger(
        _ symbol: Symbol,
        period: Int = 20,
        stddev: Decimal = 2
    ) -> (upper: Decimal, middle: Decimal, lower: Decimal)? {
        let key = BBKey(symbol: symbol, period: period, stddev: stddev)
        if bbCache[key] == nil {
            bbCache[key] = BollingerBands(period: period, stddev: stddev)
        }
        return bbCache[key]?.current
    }

    public func atr(_ symbol: Symbol, period: Int = 14) -> Decimal? {
        let key = Key(symbol: symbol, period: period)
        if atrCache[key] == nil { atrCache[key] = ATR(period: period) }
        return atrCache[key]?.current
    }
}

// MARK: - SMA

public struct SMA: Indicator {
    public let period: Int
    private var window: [Decimal] = []
    public private(set) var current: Decimal?

    public init(period: Int) {
        precondition(period > 0, "SMA period must be positive")
        self.period = period
    }

    public mutating func update(_ bar: Bar) -> Decimal? {
        window.append(bar.close)
        if window.count > period { window.removeFirst() }
        if window.count == period {
            current = window.reduce(0, +) / Decimal(period)
        }
        return current
    }
}

// MARK: - EMA

public struct EMA: Indicator {
    public let period: Int
    private let alpha: Decimal
    private var seeded = false
    private var seedBuffer: [Decimal] = []
    public private(set) var current: Decimal?

    public init(period: Int) {
        precondition(period > 0, "EMA period must be positive")
        self.period = period
        self.alpha = 2 / Decimal(period + 1)
    }

    public mutating func update(_ bar: Bar) -> Decimal? {
        if !seeded {
            seedBuffer.append(bar.close)
            if seedBuffer.count == period {
                current = seedBuffer.reduce(0, +) / Decimal(period)
                seeded = true
            }
            return current
        }
        guard let prev = current else { return nil }
        current = (bar.close * alpha) + (prev * (1 - alpha))
        return current
    }
}

// MARK: - RSI (Wilder's smoothing)

public struct RSI: Indicator {
    public let period: Int
    private var previousClose: Decimal?
    private var avgGain: Decimal = 0
    private var avgLoss: Decimal = 0
    private var samples = 0
    public private(set) var current: Decimal?

    public init(period: Int = 14) {
        precondition(period > 0, "RSI period must be positive")
        self.period = period
    }

    public mutating func update(_ bar: Bar) -> Decimal? {
        defer { previousClose = bar.close }
        guard let prev = previousClose else { return nil }

        let change = bar.close - prev
        let gain = max(change, 0)
        let loss = max(-change, 0)

        samples += 1
        if samples <= period {
            // Simple average over first N samples to seed Wilder's smoothing
            avgGain = ((avgGain * Decimal(samples - 1)) + gain) / Decimal(samples)
            avgLoss = ((avgLoss * Decimal(samples - 1)) + loss) / Decimal(samples)
            if samples == period { current = computeRSI() }
        } else {
            avgGain = ((avgGain * Decimal(period - 1)) + gain) / Decimal(period)
            avgLoss = ((avgLoss * Decimal(period - 1)) + loss) / Decimal(period)
            current = computeRSI()
        }
        return current
    }

    private func computeRSI() -> Decimal {
        guard avgLoss > 0 else { return 100 }
        let rs = avgGain / avgLoss
        return 100 - (100 / (1 + rs))
    }
}

// MARK: - MACD

/// Moving Average Convergence Divergence.
///
/// Composes two EMAs (fast, slow) and a third EMA over the (fast - slow) line for
/// the signal. Returns nil until both component EMAs are seeded AND the signal
/// EMA has accumulated enough samples to seed itself.
public struct MACD: Indicator {
    public let fast: Int
    public let slow: Int
    public let signal: Int

    private var fastEMA: EMA
    private var slowEMA: EMA
    private var signalEMA: EMA

    public private(set) var current: (macd: Decimal, signal: Decimal, histogram: Decimal)?

    public init(fast: Int = 12, slow: Int = 26, signal: Int = 9) {
        precondition(fast > 0 && slow > 0 && signal > 0, "MACD periods must be positive")
        precondition(fast < slow, "MACD fast period must be less than slow period")
        self.fast = fast
        self.slow = slow
        self.signal = signal
        self.fastEMA = EMA(period: fast)
        self.slowEMA = EMA(period: slow)
        self.signalEMA = EMA(period: signal)
    }

    public mutating func update(_ bar: Bar) -> (macd: Decimal, signal: Decimal, histogram: Decimal)? {
        let f = fastEMA.update(bar)
        let s = slowEMA.update(bar)
        guard let fast = f, let slow = s else {
            current = nil
            return nil
        }
        let macdLine = fast - slow
        // Feed the macd line into the signal EMA via a synthetic bar (close=macdLine).
        let proxy = Bar(
            symbol: bar.symbol,
            timestamp: bar.timestamp,
            open: macdLine, high: macdLine, low: macdLine, close: macdLine,
            volume: 0
        )
        guard let sig = signalEMA.update(proxy) else {
            current = nil
            return nil
        }
        let value = (macd: macdLine, signal: sig, histogram: macdLine - sig)
        current = value
        return value
    }
}

// MARK: - Bollinger Bands

/// Bollinger Bands: SMA(period) for the middle, +/- stddev * population stddev for
/// upper and lower. Returns nil until the SMA is seeded.
public struct BollingerBands: Indicator {
    public let period: Int
    public let stddev: Decimal
    private var window: [Decimal] = []
    public private(set) var current: (upper: Decimal, middle: Decimal, lower: Decimal)?

    public init(period: Int = 20, stddev: Decimal = 2) {
        precondition(period > 1, "Bollinger period must be > 1")
        precondition(stddev >= 0, "Bollinger stddev multiplier must be non-negative")
        self.period = period
        self.stddev = stddev
    }

    public mutating func update(_ bar: Bar) -> (upper: Decimal, middle: Decimal, lower: Decimal)? {
        window.append(bar.close)
        if window.count > period { window.removeFirst() }
        guard window.count == period else {
            current = nil
            return nil
        }
        let mean = window.reduce(0, +) / Decimal(period)
        var variance: Decimal = 0
        for v in window {
            let diff = v - mean
            variance += diff * diff
        }
        variance /= Decimal(period)
        let sd = Self.decimalSqrt(variance)
        let band = sd * stddev
        let value = (upper: mean + band, middle: mean, lower: mean - band)
        current = value
        return value
    }

    private static func decimalSqrt(_ value: Decimal) -> Decimal {
        guard value > 0 else { return 0 }
        let d = NSDecimalNumber(decimal: value).doubleValue
        return Decimal(Foundation.sqrt(d))
    }
}

// MARK: - ATR (Wilder's smoothing)

/// Average True Range. true_range = max(high - low, |high - prevClose|, |low - prevClose|).
/// Smoothed with Wilder's method (simple mean for the first `period` samples,
/// then `((avgTR * (period - 1)) + tr) / period` thereafter).
public struct ATR: Indicator {
    public let period: Int
    private var previousClose: Decimal?
    private var avgTR: Decimal = 0
    private var samples = 0
    public private(set) var current: Decimal?

    public init(period: Int = 14) {
        precondition(period > 0, "ATR period must be positive")
        self.period = period
    }

    public mutating func update(_ bar: Bar) -> Decimal? {
        defer { previousClose = bar.close }
        let tr: Decimal
        if let prev = previousClose {
            let hl = bar.high - bar.low
            let hpc = abs(bar.high - prev)
            let lpc = abs(bar.low - prev)
            tr = max(hl, max(hpc, lpc))
        } else {
            tr = bar.high - bar.low
        }

        samples += 1
        if samples <= period {
            avgTR = ((avgTR * Decimal(samples - 1)) + tr) / Decimal(samples)
            if samples == period { current = avgTR }
        } else {
            avgTR = ((avgTR * Decimal(period - 1)) + tr) / Decimal(period)
            current = avgTR
        }
        return current
    }
}
