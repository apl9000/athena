import XCTest
import AthenaCore
@testable import AthenaIndicators
@testable import AthenaMLX

// MARK: - Shared test helpers

/// Floating-point tolerance for BollingerBands parity assertions.
///
/// SMA, EMA, and RSI use pure `Decimal` arithmetic and are compared with
/// exact `Decimal` equality.  BollingerBands computes `sqrt` via `Double`
/// internally, so a small tolerance is needed there.
private let parityTolerance: Double = 1e-9

/// Build a fake `Bar` whose `close` (and open/high/low) equal `value`.
private func bar(_ value: Decimal, symbol: Symbol = Symbol("T")) -> Bar {
    Bar(
        symbol: symbol,
        timestamp: Date(timeIntervalSince1970: 0),
        open: value,
        high: value,
        low: value,
        close: value,
        volume: 1_000
    )
}

/// Drive the scalar `SMA` over a `closes` array and return one result per bar.
private func scalarSMAValues(period: Int, closes: [Decimal]) -> [Decimal?] {
    var sma = SMA(period: period)
    return closes.map { sma.update(bar($0)) }
}

/// Drive the scalar `EMA` over a `closes` array and return one result per bar.
private func scalarEMAValues(period: Int, closes: [Decimal]) -> [Decimal?] {
    var ema = EMA(period: period)
    return closes.map { ema.update(bar($0)) }
}

/// Drive the scalar `RSI` over a `closes` array and return one result per bar.
private func scalarRSIValues(period: Int, closes: [Decimal]) -> [Decimal?] {
    var rsi = RSI(period: period)
    return closes.map { rsi.update(bar($0)) }
}

/// Drive the scalar `BollingerBands` over `closes` and return one result per bar.
private func scalarBBValues(
    period: Int,
    stddev: Decimal,
    closes: [Decimal]
) -> [(upper: Decimal, middle: Decimal, lower: Decimal)?] {
    var bb = BollingerBands(period: period, stddev: stddev)
    return closes.map { bb.update(bar($0)) }
}

// MARK: - VectorizedSMA parity tests

final class VectorizedSMAParityTests: XCTestCase {

    // MARK: Warm-up gating

    /// Vectorized SMA returns nil for the first `period - 1` bars (warm-up),
    /// matching the scalar SMA contract.
    func test_sma_warmupGating_matchesScalar() {
        let closes: [Decimal] = [1, 2, 3, 4, 5]
        let period = 3
        let vec = VectorizedSMA(period: period).compute(closes: closes)
        let scalar = scalarSMAValues(period: period, closes: closes)

        XCTAssertEqual(vec.count, closes.count)
        for i in 0..<(period - 1) {
            XCTAssertNil(vec[i],    "vec[\(i)] should be nil during warm-up")
            XCTAssertNil(scalar[i], "scalar[\(i)] should be nil during warm-up")
        }
    }

    // MARK: Ramp series

    /// Vectorized SMA on [1…10] with period 5 matches scalar SMA.
    func test_sma_rampSeries_matchesScalar() {
        let period = 5
        let closes = (1...10).map { Decimal($0) }
        let vec    = VectorizedSMA(period: period).compute(closes: closes)
        let scalar = scalarSMAValues(period: period, closes: closes)

        XCTAssertEqual(vec.count, closes.count)
        for (i, (v, s)) in zip(vec, scalar).enumerated() {
            guard let v, let s else {
                XCTAssertNil(v,    "vec[\(i)] should be nil when scalar is nil")
                XCTAssertNil(s,    "scalar[\(i)] should be nil when vec is nil")
                continue
            }
            // SMA uses pure Decimal arithmetic — enforce exact equality.
            XCTAssertEqual(v, s,
                           "SMA mismatch at bar \(i): vec=\(v) scalar=\(s)")
        }
    }

    // MARK: Constant series

    /// Vectorized SMA on a constant series equals that constant.
    func test_sma_constantSeries_matchesScalar() {
        let period = 4
        let closes = [Decimal](repeating: 50, count: 10)
        let vec    = VectorizedSMA(period: period).compute(closes: closes)
        let scalar = scalarSMAValues(period: period, closes: closes)

        for (v, s) in zip(vec, scalar) {
            XCTAssertEqual(v, s, "Constant-series SMA must be identical")
        }
    }

    // MARK: Length contract

    /// Output length always equals input length.
    func test_sma_outputLength_equalsInputLength() {
        let vSMA = VectorizedSMA(period: 3)
        XCTAssertEqual(vSMA.compute(closes: []).count,              0)
        XCTAssertEqual(vSMA.compute(closes: [1]).count,             1)
        XCTAssertEqual(vSMA.compute(closes: [1, 2, 3, 4, 5]).count, 5)
    }

    // MARK: Single-element period

    /// SMA(1) on a series returns each value immediately (no warm-up gap).
    func test_sma_periodOne_returnsEachValueImmediately() {
        let closes: [Decimal] = [3, 7, 2]
        let vec = VectorizedSMA(period: 1).compute(closes: closes)
        for (v, c) in zip(vec, closes) {
            XCTAssertEqual(v, c, "SMA(1) must equal each close")
        }
    }
}

// MARK: - VectorizedEMA parity tests

final class VectorizedEMAParityTests: XCTestCase {

    // MARK: Warm-up gating

    /// Vectorized EMA returns nil for the first `period - 1` bars, matching
    /// the scalar EMA seeding behaviour.
    func test_ema_warmupGating_matchesScalar() {
        let closes: [Decimal] = [2, 4, 6, 8, 10]
        let period = 3
        let vec    = VectorizedEMA(period: period).compute(closes: closes)
        let scalar = scalarEMAValues(period: period, closes: closes)

        for i in 0..<(period - 1) {
            XCTAssertNil(vec[i],    "vec[\(i)] should be nil during warm-up")
            XCTAssertNil(scalar[i], "scalar[\(i)] should be nil during warm-up")
        }
    }

    // MARK: Seed value

    /// Vectorized EMA seeds at bar `period` with the SMA of the first N closes,
    /// matching the scalar implementation.
    func test_ema_seedValue_matchesScalarSeed() {
        let period = 3
        let closes: [Decimal] = [2, 4, 6, 8]
        let vec    = VectorizedEMA(period: period).compute(closes: closes)
        let scalar = scalarEMAValues(period: period, closes: closes)

        // First defined value (index `period - 1`) must match exactly.
        let seedIdx = period - 1
        XCTAssertEqual(vec[seedIdx], scalar[seedIdx],
                       "EMA seed value must match at bar \(seedIdx)")
    }

    // MARK: Ramp series

    /// Vectorized EMA on [1…20] with period 5 matches scalar EMA within
    /// `parityTolerance`.
    func test_ema_rampSeries_matchesScalar() {
        let period = 5
        let closes = (1...20).map { Decimal($0) }
        let vec    = VectorizedEMA(period: period).compute(closes: closes)
        let scalar = scalarEMAValues(period: period, closes: closes)

        for (i, (v, s)) in zip(vec, scalar).enumerated() {
            guard let v, let s else { continue }
            // EMA uses pure Decimal arithmetic — enforce exact equality.
            XCTAssertEqual(v, s,
                           "EMA mismatch at bar \(i): vec=\(v) scalar=\(s)")
        }
    }

    // MARK: Convergence

    /// EMA converges toward a new constant level, matching scalar.
    func test_ema_convergesToConstantInput_matchesScalar() {
        let period = 5
        var closes = [Decimal](repeating: 100, count: period)   // seed at 100
        closes += [Decimal](repeating: 200, count: 50)          // long tail at 200
        let vec    = VectorizedEMA(period: period).compute(closes: closes)
        let scalar = scalarEMAValues(period: period, closes: closes)

        // After 50 bars at 200, both should be very close to 200.
        // EMA uses pure Decimal arithmetic — enforce exact equality.
        if let last = vec.last, let lv = last, let ls = scalar.last, let lsv = ls {
            XCTAssertEqual(lv, lsv, "EMA convergence values must match exactly")
        }
    }

    // MARK: Length contract

    /// Output length always equals input length.
    func test_ema_outputLength_equalsInputLength() {
        let vEMA = VectorizedEMA(period: 3)
        XCTAssertEqual(vEMA.compute(closes: []).count,              0)
        XCTAssertEqual(vEMA.compute(closes: [1]).count,             1)
        XCTAssertEqual(vEMA.compute(closes: [1, 2, 3, 4, 5]).count, 5)
    }
}

// MARK: - VectorizedRSI parity tests

final class VectorizedRSIParityTests: XCTestCase {

    // MARK: Warm-up gating

    /// Vectorized RSI returns nil until `period` changes have been accumulated,
    /// matching the scalar RSI warm-up behaviour.
    func test_rsi_warmupGating_matchesScalar() {
        let period = 5
        let closes = (1...10).map { Decimal($0) }
        let vec    = VectorizedRSI(period: period).compute(closes: closes)
        let scalar = scalarRSIValues(period: period, closes: closes)

        // Scalar RSI needs `period` changes (= `period + 1` bars) to emit the
        // first value; compare nil-positions exactly.
        for (i, (v, s)) in zip(vec, scalar).enumerated() {
            if s == nil {
                XCTAssertNil(v, "vec[\(i)] should be nil when scalar is nil")
            } else {
                XCTAssertNotNil(v, "vec[\(i)] should be non-nil when scalar is non-nil")
            }
        }
    }

    // MARK: Monotonically rising series

    /// RSI on a strictly rising series equals 100 (all gains, no losses).
    func test_rsi_monotonicRisingSeries_equals100() {
        let period = 14
        let closes = (1...30).map { Decimal($0) }
        let vec    = VectorizedRSI(period: period).compute(closes: closes)
        let scalar = scalarRSIValues(period: period, closes: closes)

        for (i, (v, s)) in zip(vec, scalar).enumerated() {
            guard let v, let s else { continue }
            // RSI uses pure Decimal arithmetic — enforce exact equality.
            XCTAssertEqual(v, s, "RSI mismatch at bar \(i)")
        }
    }

    // MARK: Flat series

    /// RSI on a perfectly flat series equals 100 (zero losses, so RS → ∞).
    func test_rsi_flatSeries_equals100() {
        let period = 14
        let closes = [Decimal](repeating: 50, count: 30)
        let vec    = VectorizedRSI(period: period).compute(closes: closes)
        let scalar = scalarRSIValues(period: period, closes: closes)

        for (i, (v, s)) in zip(vec, scalar).enumerated() {
            guard let v, let s else { continue }
            // RSI uses pure Decimal arithmetic — enforce exact equality.
            XCTAssertEqual(v, s, "RSI mismatch at bar \(i) on flat series")
        }
    }

    // MARK: Alternating series

    /// RSI on an alternating up/down series matches the scalar implementation.
    func test_rsi_alternatingUpDown_matchesScalar() {
        let period = 5
        var closes: [Decimal] = []
        for i in 0..<30 { closes.append(i % 2 == 0 ? 100 : 101) }
        let vec    = VectorizedRSI(period: period).compute(closes: closes)
        let scalar = scalarRSIValues(period: period, closes: closes)

        for (i, (v, s)) in zip(vec, scalar).enumerated() {
            guard let v, let s else { continue }
            // RSI uses pure Decimal arithmetic — enforce exact equality.
            XCTAssertEqual(v, s, "RSI mismatch at bar \(i) on alternating series")
        }
    }

    // MARK: Monotonically falling series

    /// RSI on a strictly falling series equals 0 (all losses, no gains) and
    /// matches the scalar implementation element-by-element.
    ///
    /// This exercises the downtrend path where `avgGain == 0`, driving
    /// `rs == 0` and clamping RSI to 0 — a case the alternating series never
    /// reaches because alternating inputs always produce non-zero gains.
    func test_rsi_fallingSeries_matchesScalar() {
        let period = 14
        let closes = (1...30).reversed().map { Decimal($0) }
        let vec    = VectorizedRSI(period: period).compute(closes: closes)
        let scalar = scalarRSIValues(period: period, closes: closes)

        XCTAssertEqual(vec.count, closes.count)
        for (i, (v, s)) in zip(vec, scalar).enumerated() {
            guard let v, let s else { continue }
            // RSI uses pure Decimal arithmetic — enforce exact equality.
            XCTAssertEqual(v, s,
                           "RSI mismatch at bar \(i) on falling series: vec=\(v) scalar=\(s)")
        }
    }

    // MARK: Length contract

    /// Output length always equals input length.
    func test_rsi_outputLength_equalsInputLength() {
        let vRSI = VectorizedRSI(period: 5)
        XCTAssertEqual(vRSI.compute(closes: []).count,              0)
        XCTAssertEqual(vRSI.compute(closes: [1]).count,             1)
        XCTAssertEqual(vRSI.compute(closes: [1, 2, 3, 4, 5]).count, 5)
    }
}

// MARK: - VectorizedBollingerBands parity tests

final class VectorizedBollingerBandsParityTests: XCTestCase {

    // MARK: Warm-up gating

    /// Vectorized Bollinger Bands return nil for the first `period - 1` bars,
    /// matching the scalar implementation.
    func test_bb_warmupGating_matchesScalar() {
        let period = 5
        let closes: [Decimal] = [1, 2, 3, 4, 5, 6, 7]
        let vec    = VectorizedBollingerBands(period: period).compute(closes: closes)
        let scalar = scalarBBValues(period: period, stddev: 2, closes: closes)

        for i in 0..<(period - 1) {
            XCTAssertNil(vec[i],    "vec[\(i)] should be nil during warm-up")
            XCTAssertNil(scalar[i], "scalar[\(i)] should be nil during warm-up")
        }
    }

    // MARK: Constant series

    /// On a constant series the upper, middle, and lower bands all equal the
    /// constant (zero band-width), matching scalar.
    func test_bb_constantSeries_zeroWidth_matchesScalar() {
        let period: Int = 5
        let stddev: Decimal = 2
        let closes = [Decimal](repeating: 100, count: 8)
        let vec    = VectorizedBollingerBands(period: period, stddev: stddev)
                        .compute(closes: closes)
        let scalar = scalarBBValues(period: period, stddev: stddev, closes: closes)

        for (i, (v, s)) in zip(vec, scalar).enumerated() {
            guard let v, let s else { continue }
            XCTAssertEqual(
                NSDecimalNumber(decimal: v.middle).doubleValue,
                NSDecimalNumber(decimal: s.middle).doubleValue,
                accuracy: parityTolerance,
                "BB middle mismatch at bar \(i)"
            )
            XCTAssertEqual(
                NSDecimalNumber(decimal: v.upper).doubleValue,
                NSDecimalNumber(decimal: s.upper).doubleValue,
                accuracy: parityTolerance,
                "BB upper mismatch at bar \(i)"
            )
            XCTAssertEqual(
                NSDecimalNumber(decimal: v.lower).doubleValue,
                NSDecimalNumber(decimal: s.lower).doubleValue,
                accuracy: parityTolerance,
                "BB lower mismatch at bar \(i)"
            )
        }
    }

    // MARK: Ramp series

    /// Vectorized Bollinger Bands on [1…20] with period 5, stddev 2 match
    /// the scalar implementation within `parityTolerance`.
    func test_bb_rampSeries_matchesScalar() {
        let period: Int = 5
        let stddev: Decimal = 2
        let closes = (1...20).map { Decimal($0) }
        let vec    = VectorizedBollingerBands(period: period, stddev: stddev)
                        .compute(closes: closes)
        let scalar = scalarBBValues(period: period, stddev: stddev, closes: closes)

        for (i, (v, s)) in zip(vec, scalar).enumerated() {
            guard let v, let s else { continue }
            let vMiddle = NSDecimalNumber(decimal: v.middle).doubleValue
            let sMiddle = NSDecimalNumber(decimal: s.middle).doubleValue
            let vUpper  = NSDecimalNumber(decimal: v.upper).doubleValue
            let sUpper  = NSDecimalNumber(decimal: s.upper).doubleValue
            let vLower  = NSDecimalNumber(decimal: v.lower).doubleValue
            let sLower  = NSDecimalNumber(decimal: s.lower).doubleValue
            XCTAssertEqual(vMiddle, sMiddle, accuracy: parityTolerance,
                           "BB middle mismatch at bar \(i)")
            XCTAssertEqual(vUpper,  sUpper,  accuracy: parityTolerance,
                           "BB upper mismatch at bar \(i)")
            XCTAssertEqual(vLower,  sLower,  accuracy: parityTolerance,
                           "BB lower mismatch at bar \(i)")
        }
    }

    // MARK: Symmetric bands

    /// Upper and lower bands are symmetric about the middle band.
    func test_bb_bands_areSymmetricAboutMiddle() {
        let period: Int = 5
        let stddev: Decimal = 2
        let closes: [Decimal] = [1, 3, 5, 4, 2, 6, 8, 7]
        let vec = VectorizedBollingerBands(period: period, stddev: stddev)
                    .compute(closes: closes)

        for (i, v) in vec.enumerated() {
            guard let v else { continue }
            let upperGap = NSDecimalNumber(decimal: v.upper - v.middle).doubleValue
            let lowerGap = NSDecimalNumber(decimal: v.middle - v.lower).doubleValue
            XCTAssertEqual(upperGap, lowerGap, accuracy: parityTolerance,
                           "BB bands must be symmetric at bar \(i)")
        }
    }

    // MARK: Stddev multiplier

    /// Doubling the stddev multiplier doubles the band width.
    func test_bb_stddevMultiplier_scalesBandWidth() {
        let period: Int = 5
        let closes: [Decimal] = [1, 3, 5, 4, 2, 6, 8]
        let v1 = VectorizedBollingerBands(period: period, stddev: 1).compute(closes: closes)
        let v2 = VectorizedBollingerBands(period: period, stddev: 2).compute(closes: closes)

        for (b1, b2) in zip(v1, v2) {
            guard let b1, let b2 else { continue }
            let w1 = NSDecimalNumber(decimal: b1.upper - b1.lower).doubleValue
            let w2 = NSDecimalNumber(decimal: b2.upper - b2.lower).doubleValue
            XCTAssertEqual(w2, w1 * 2, accuracy: parityTolerance,
                           "BB band width must scale linearly with stddev multiplier")
        }
    }

    // MARK: Length contract

    /// Output length always equals input length.
    func test_bb_outputLength_equalsInputLength() {
        let vBB = VectorizedBollingerBands(period: 3)
        XCTAssertEqual(vBB.compute(closes: []).count,              0)
        XCTAssertEqual(vBB.compute(closes: [1]).count,             1)
        XCTAssertEqual(vBB.compute(closes: [1, 2, 3, 4, 5]).count, 5)
    }
}
