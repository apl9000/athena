import XCTest
import AthenaCore
@testable import AthenaIndicators

final class IndicatorsTests: XCTestCase {

    private func bar(_ close: Decimal, high: Decimal? = nil, low: Decimal? = nil, ts: TimeInterval = 0) -> Bar {
        Bar(
            symbol: Symbol("X"),
            timestamp: Date(timeIntervalSince1970: ts),
            open: close, high: high ?? close, low: low ?? close, close: close,
            volume: 1_000
        )
    }

    func testSMAOnRamp() {
        var sma = SMA(period: 5)
        var outputs: [Decimal] = []
        for v: Decimal in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] {
            if let r = sma.update(bar(v)) { outputs.append(r) }
        }
        XCTAssertEqual(outputs, [3, 4, 5, 6, 7, 8])
    }

    func testSMAReturnsNilBeforeWarmup() {
        var sma = SMA(period: 3)
        XCTAssertNil(sma.update(bar(1)))
        XCTAssertNil(sma.update(bar(2)))
        XCTAssertEqual(sma.update(bar(3)), 2)
        XCTAssertEqual(sma.current, 2)
    }

    func testEMASeedsWithSMAOfFirstNCloses() {
        var ema = EMA(period: 3)
        XCTAssertNil(ema.update(bar(2)))
        XCTAssertNil(ema.update(bar(4)))
        XCTAssertEqual(ema.update(bar(6)), 4)
    }

    func testEMAConvergesTowardConstantInput() {
        var ema = EMA(period: 5)
        for _ in 0..<5 { _ = ema.update(bar(100)) }
        for _ in 0..<50 { _ = ema.update(bar(200)) }
        let v = ema.current ?? 0
        XCTAssertEqual(NSDecimalNumber(decimal: v).doubleValue, 200, accuracy: 0.5)
    }

    func testRSIOnMonotonicallyRisingSeries() {
        var rsi = RSI(period: 14)
        for i in 1...30 { _ = rsi.update(bar(Decimal(i))) }
        XCTAssertEqual(rsi.current, 100)
    }

    func testRSIOnFlatSeries() {
        var rsi = RSI(period: 14)
        for _ in 0..<30 { _ = rsi.update(bar(50)) }
        XCTAssertEqual(rsi.current, 100)
    }

    func testMACDReturnsNilBeforeSeed() {
        var macd = MACD(fast: 3, slow: 6, signal: 2)
        XCTAssertNil(macd.update(bar(10)))
        XCTAssertNil(macd.current)
    }

    func testMACDProducesValueOnRamp() {
        var macd = MACD(fast: 3, slow: 6, signal: 2)
        for i in 1...20 { _ = macd.update(bar(Decimal(i))) }
        guard let v = macd.current else { return XCTFail("expected value") }
        XCTAssertGreaterThan(v.macd, 0)
        XCTAssertEqual(v.histogram, v.macd - v.signal)
    }

    func testBollingerOnConstantSeriesHasZeroBandWidth() {
        var bb = BollingerBands(period: 5, stddev: 2)
        for _ in 0..<5 { _ = bb.update(bar(100)) }
        guard let v = bb.current else { return XCTFail("expected value") }
        XCTAssertEqual(v.middle, 100)
        XCTAssertEqual(v.upper, 100)
        XCTAssertEqual(v.lower, 100)
    }

    func testBollingerOnRampHasSymmetricBands() {
        var bb = BollingerBands(period: 5, stddev: 2)
        for i: Decimal in [1, 2, 3, 4, 5] { _ = bb.update(bar(i)) }
        guard let v = bb.current else { return XCTFail("expected value") }
        XCTAssertEqual(v.middle, 3)
        let upperGap = NSDecimalNumber(decimal: v.upper - v.middle).doubleValue
        let lowerGap = NSDecimalNumber(decimal: v.middle - v.lower).doubleValue
        XCTAssertEqual(upperGap, lowerGap, accuracy: 0.0001)
        XCTAssertGreaterThan(upperGap, 0)
    }

    func testBollingerReturnsNilBeforeWarmup() {
        var bb = BollingerBands(period: 5, stddev: 2)
        XCTAssertNil(bb.update(bar(1)))
        XCTAssertNil(bb.update(bar(2)))
        XCTAssertNil(bb.update(bar(3)))
        XCTAssertNil(bb.update(bar(4)))
        XCTAssertNotNil(bb.update(bar(5)))
    }

    func testATROnConstantOHLC() {
        var atr = ATR(period: 3)
        for _ in 0..<10 { _ = atr.update(bar(100, high: 102, low: 98)) }
        guard let v = atr.current else { return XCTFail("expected value") }
        XCTAssertEqual(NSDecimalNumber(decimal: v).doubleValue, 4, accuracy: 0.001)
    }

    func testATRReturnsNilBeforeSeed() {
        var atr = ATR(period: 5)
        XCTAssertNil(atr.update(bar(100, high: 101, low: 99)))
        XCTAssertNil(atr.current)
    }

    func testCacheReturnsNilBeforeWarmup() async {
        let cache = IndicatorCache()
        let s = Symbol("X")
        let v = await cache.sma(s, period: 5)
        XCTAssertNil(v)
    }

    func testCacheUpdatesAndReturnsValue() async {
        let cache = IndicatorCache()
        let s = Symbol("X")
        _ = await cache.sma(s, period: 3)
        for v: Decimal in [1, 2, 3, 4, 5] { await cache.update(with: bar(v)) }
        let r = await cache.sma(s, period: 3)
        XCTAssertEqual(r, 4)
    }

    func testCacheIsolatesSymbols() async {
        let cache = IndicatorCache()
        let a = Symbol("A")
        let b = Symbol("B")
        _ = await cache.sma(a, period: 3)
        _ = await cache.sma(b, period: 3)
        for v: Decimal in [10, 20, 30] {
            await cache.update(with: Bar(symbol: a, timestamp: Date(),
                                         open: v, high: v, low: v, close: v, volume: 1))
        }
        let ra = await cache.sma(a, period: 3)
        let rb = await cache.sma(b, period: 3)
        XCTAssertEqual(ra, 20)
        XCTAssertNil(rb)
    }

    func testCacheAllAccessorsRegisterAndReturn() async {
        let cache = IndicatorCache()
        let s = Symbol("X")
        _ = await cache.sma(s, period: 2)
        _ = await cache.ema(s, period: 2)
        _ = await cache.rsi(s, period: 2)
        _ = await cache.macd(s, fast: 2, slow: 4, signal: 2)
        _ = await cache.bollinger(s, period: 2, stddev: 2)
        _ = await cache.atr(s, period: 2)
        for v: Decimal in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] {
            await cache.update(with: bar(v, high: v + 1, low: v - 1))
        }
        let r1 = await cache.sma(s, period: 2)
        let r2 = await cache.ema(s, period: 2)
        let r3 = await cache.atr(s, period: 2)
        let r4 = await cache.bollinger(s, period: 2, stddev: 2)
        XCTAssertNotNil(r1)
        XCTAssertNotNil(r2)
        XCTAssertNotNil(r3)
        XCTAssertNotNil(r4)
    }

    func testIndicatorProviderDefaultPeriodHelpers() async {
        let cache = IndicatorCache()
        let s = Symbol("X")
        let macd = await cache.macd(s)
        let bb = await cache.bollinger(s)
        let atr = await cache.atr(s)
        XCTAssertNil(macd)
        XCTAssertNil(bb)
        XCTAssertNil(atr)
    }
}
