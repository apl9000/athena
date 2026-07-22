import Foundation
import AthenaCore

// MARK: - Vectorized indicators (AthenaMLX-internal)
//
// These types compute indicators over an *entire* bar array in a single pass
// rather than updating state one bar at a time.  They are internal support
// for MLXBacktestRunner and must not appear in Athena's public API.
//
// v0.5 coverage: SMA, EMA, RSI (Wilder), BollingerBands.
// Parity tolerance by type:
//   SMA, EMA, RSI — exact (pure Decimal arithmetic, no rounding).
//   BollingerBands — ≤ 1e-9 (sqrt step converts to Double and back).
//
// Later slices will replace the inner loops with MLX tensor operations when
// `canImport(MLX)` is true; the public surface and test assertions are
// intentionally identical so that swap is drop-in.

// MARK: - VectorizedSMA

/// Computes Simple Moving Average over a full close-price array.
///
/// ## Behaviour
/// - Returns an array of the **same length** as `closes`.
/// - Elements `0 ..< period - 1` are `nil` (warm-up); subsequent elements
///   hold the mean of the preceding `period` closes including the current one.
///
/// ## Parity tolerance
/// Exact (`Decimal` arithmetic, no rounding).
struct VectorizedSMA {
    let period: Int

    init(period: Int) {
        precondition(period > 0, "VectorizedSMA period must be positive")
        self.period = period
    }

    /// Compute SMA over `closes`.
    ///
    /// - Parameter closes: Ordered sequence of close prices.
    /// - Returns: `[Decimal?]` of the same length; `nil` during warm-up.
    func compute(closes: [Decimal]) -> [Decimal?] {
        guard !closes.isEmpty else { return [] }
        var result = [Decimal?](repeating: nil, count: closes.count)
        var windowSum: Decimal = 0

        for i in closes.indices {
            windowSum += closes[i]
            if i >= period {
                windowSum -= closes[i - period]
            }
            if i >= period - 1 {
                result[i] = windowSum / Decimal(period)
            }
        }
        return result
    }
}

// MARK: - VectorizedEMA

/// Computes Exponential Moving Average over a full close-price array.
///
/// ## Seeding
/// Seeds with the SMA of the first `period` closes, then applies the
/// standard EMA smoothing factor `α = 2 / (period + 1)` for every
/// subsequent bar — identical to `AthenaIndicators.EMA`.
///
/// ## Parity tolerance
/// Exact (`Decimal` arithmetic, no rounding).
struct VectorizedEMA {
    let period: Int

    init(period: Int) {
        precondition(period > 0, "VectorizedEMA period must be positive")
        self.period = period
    }

    /// Compute EMA over `closes`.
    ///
    /// - Parameter closes: Ordered sequence of close prices.
    /// - Returns: `[Decimal?]` of the same length; `nil` during warm-up.
    func compute(closes: [Decimal]) -> [Decimal?] {
        guard !closes.isEmpty else { return [] }
        var result = [Decimal?](repeating: nil, count: closes.count)
        let alpha: Decimal = 2 / Decimal(period + 1)

        var seedSum: Decimal = 0
        var current: Decimal?

        for i in closes.indices {
            if i < period {
                // Accumulate seed window (SMA of first `period` closes).
                seedSum += closes[i]
                if i == period - 1 {
                    current = seedSum / Decimal(period)
                    result[i] = current
                }
            } else {
                guard let prev = current else { continue }
                current = (closes[i] * alpha) + (prev * (1 - alpha))
                result[i] = current
            }
        }
        return result
    }
}

// MARK: - VectorizedRSI

/// Computes RSI (Wilder's smoothed) over a full close-price array.
///
/// ## Algorithm
/// Matches `AthenaIndicators.RSI` exactly:
/// 1. Needs at least one prior close to compute a change.
/// 2. Seeds the average gain/loss with a simple mean over the first `period`
///    changes (= bars `1 ..< period + 1`).
/// 3. After seeding, applies Wilder's exponential smoothing.
///
/// ## Parity tolerance
/// Exact (`Decimal` arithmetic, no rounding).
struct VectorizedRSI {
    let period: Int

    init(period: Int = 14) {
        precondition(period > 0, "VectorizedRSI period must be positive")
        self.period = period
    }

    /// Compute RSI over `closes`.
    ///
    /// - Parameter closes: Ordered sequence of close prices.
    /// - Returns: `[Decimal?]` of the same length; `nil` until seeded.
    func compute(closes: [Decimal]) -> [Decimal?] {
        guard !closes.isEmpty else { return [] }
        var result = [Decimal?](repeating: nil, count: closes.count)
        var avgGain: Decimal = 0
        var avgLoss: Decimal = 0
        var samples = 0

        for i in 1..<closes.count {
            let change = closes[i] - closes[i - 1]
            let gain   = max(change,  0)
            let loss   = max(-change, 0)

            samples += 1
            if samples <= period {
                // Simple average seeding (identical to scalar RSI)
                avgGain = ((avgGain * Decimal(samples - 1)) + gain) / Decimal(samples)
                avgLoss = ((avgLoss * Decimal(samples - 1)) + loss) / Decimal(samples)
                if samples == period {
                    result[i] = computeRSI(avgGain: avgGain, avgLoss: avgLoss)
                }
            } else {
                // Wilder's exponential smoothing
                avgGain = ((avgGain * Decimal(period - 1)) + gain) / Decimal(period)
                avgLoss = ((avgLoss * Decimal(period - 1)) + loss) / Decimal(period)
                result[i] = computeRSI(avgGain: avgGain, avgLoss: avgLoss)
            }
        }
        return result
    }

    private func computeRSI(avgGain: Decimal, avgLoss: Decimal) -> Decimal {
        guard avgLoss > 0 else { return 100 }
        let rs = avgGain / avgLoss
        return 100 - (100 / (1 + rs))
    }
}

// MARK: - VectorizedBollingerBands

/// Computes Bollinger Bands over a full close-price array.
///
/// Middle = SMA(period). Upper = middle + stddev * σ. Lower = middle − stddev * σ.
/// Population standard deviation (not Bessel-corrected), matching
/// `AthenaIndicators.BollingerBands`.
///
/// ## Parity tolerance
/// ≤ 1e-9 (the `sqrt` step converts to `Double` and back to `Decimal`,
/// matching the scalar implementation exactly).
struct VectorizedBollingerBands {
    let period: Int
    let stddev: Decimal

    init(period: Int = 20, stddev: Decimal = 2) {
        precondition(period > 1, "VectorizedBollingerBands period must be > 1")
        precondition(stddev >= 0, "VectorizedBollingerBands stddev multiplier must be non-negative")
        self.period = period
        self.stddev = stddev
    }

    /// Compute Bollinger Bands over `closes`.
    ///
    /// - Parameter closes: Ordered sequence of close prices.
    /// - Returns: Array of optional `(upper, middle, lower)` tuples of the
    ///   same length; `nil` during warm-up.
    func compute(closes: [Decimal]) -> [(upper: Decimal, middle: Decimal, lower: Decimal)?] {
        guard !closes.isEmpty else { return [] }
        var result = [(upper: Decimal, middle: Decimal, lower: Decimal)?](
            repeating: nil, count: closes.count
        )
        // Rolling sums maintained in O(1) per bar.
        var windowSum:   Decimal = 0
        var windowSumSq: Decimal = 0

        for i in closes.indices {
            let c = closes[i]
            windowSum   += c
            windowSumSq += c * c
            if i >= period {
                let old = closes[i - period]
                windowSum   -= old
                windowSumSq -= old * old
            }
            guard i >= period - 1 else { continue }

            let mean = windowSum / Decimal(period)
            // Population variance via the computational formula: E[X²] − (E[X])²
            // Equivalent to the two-pass sum-of-squared-deviations formula with
            // exact Decimal arithmetic; used here to keep the loop O(n) total.
            let variance = windowSumSq / Decimal(period) - mean * mean

            let sd   = decimalSqrt(variance)
            let band = sd * stddev
            result[i] = (upper: mean + band, middle: mean, lower: mean - band)
        }
        return result
    }

    // Uses the same Double-bridged sqrt as the scalar BollingerBands, ensuring
    // the parity tolerance is met trivially.
    private func decimalSqrt(_ value: Decimal) -> Decimal {
        guard value > 0 else { return 0 }
        let d = NSDecimalNumber(decimal: value).doubleValue
        return Decimal(Foundation.sqrt(d))
    }
}
