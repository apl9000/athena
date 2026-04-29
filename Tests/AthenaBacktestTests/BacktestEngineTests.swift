import XCTest
import AthenaCore
import AthenaIndicators
import AthenaBrokers
import AthenaData
@testable import AthenaBacktest

private struct CrossStrategy: Strategy {
    let symbol: Symbol
    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard
            let fast = await context.indicators.sma(symbol, period: 5),
            let slow = await context.indicators.sma(symbol, period: 20)
        else { return }
        let pos = await context.portfolio.position(for: symbol)
        let qty = pos?.quantity ?? 0
        if fast > slow, qty == 0 {
            _ = try? await context.buy(symbol, quantity: 1)
        } else if fast < slow, qty > 0 {
            _ = try? await context.sell(symbol, quantity: qty)
        }
    }
}

final class BacktestEngineTests: XCTestCase {

    private func snap(_ value: Decimal, ts: TimeInterval = 0) -> PortfolioSnapshot {
        PortfolioSnapshot(
            timestamp: Date(timeIntervalSince1970: ts),
            totalValue: Money(value, .usd),
            cash: [.usd: value],
            positions: [:]
        )
    }

    func testTotalReturnPositive() {
        let r = BacktestResult(initialEquity: .usd(1000), finalEquity: .usd(1500),
                               snapshots: [], fills: [])
        XCTAssertEqual(r.totalReturn, Decimal(string: "0.5"))
    }

    func testTotalReturnNegative() {
        let r = BacktestResult(initialEquity: .usd(1000), finalEquity: .usd(800),
                               snapshots: [], fills: [])
        XCTAssertEqual(r.totalReturn, Decimal(string: "-0.2"))
    }

    func testTotalReturnZeroInitialIsZero() {
        let r = BacktestResult(initialEquity: .usd(0), finalEquity: .usd(1000),
                               snapshots: [], fills: [])
        XCTAssertEqual(r.totalReturn, 0)
    }

    func testMaxDrawdownMonotonicUp() {
        let r = BacktestResult(
            initialEquity: .usd(100), finalEquity: .usd(120),
            snapshots: [snap(100, ts: 0), snap(110, ts: 1), snap(120, ts: 2)],
            fills: []
        )
        XCTAssertEqual(r.maxDrawdown, 0)
    }

    func testMaxDrawdownVShape() {
        let r = BacktestResult(
            initialEquity: .usd(100), finalEquity: .usd(100),
            snapshots: [snap(100), snap(150), snap(75), snap(100)],
            fills: []
        )
        XCTAssertEqual(r.maxDrawdown, Decimal(string: "0.5"))
    }

    func testSharpeWithLessThanTwoSnapshotsIsZero() {
        let r0 = BacktestResult(initialEquity: .usd(100), finalEquity: .usd(100),
                                snapshots: [], fills: [])
        XCTAssertEqual(r0.sharpe, 0)
        let r1 = BacktestResult(initialEquity: .usd(100), finalEquity: .usd(100),
                                snapshots: [snap(100)], fills: [])
        XCTAssertEqual(r1.sharpe, 0)
    }

    func testSharpeOnFlatCurveIsZero() {
        let r = BacktestResult(
            initialEquity: .usd(100), finalEquity: .usd(100),
            snapshots: [snap(100), snap(100), snap(100)],
            fills: []
        )
        XCTAssertEqual(r.sharpe, 0)
    }

    func testSharpeOnRisingCurveIsPositive() {
        let snaps = (0...10).map { snap(Decimal(100 + $0), ts: TimeInterval($0)) }
        let r = BacktestResult(initialEquity: .usd(100), finalEquity: .usd(110),
                               snapshots: snaps, fills: [])
        XCTAssertGreaterThan(r.sharpe, 0)
    }

    func testBacktestConfigDefaults() {
        let c = BacktestConfig(
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 100),
            initialCash: .usd(1000)
        )
        XCTAssertNotNil(c.commission as? FreeCommission)
        XCTAssertNotNil(c.slippage as? FixedBpsSlippage)
    }

    private func syntheticBars(_ n: Int = 500, symbol: Symbol = Symbol("SYN")) -> [Bar] {
        var bars: [Bar] = []
        bars.reserveCapacity(n)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let oneDay: TimeInterval = 86_400
        for i in 0..<n {
            let t = start.addingTimeInterval(Double(i) * oneDay)
            let close = 100.0 + 20.0 * Foundation.sin(Double(i) * 2.0 * .pi / 50.0)
            let dec = Decimal(close)
            bars.append(Bar(
                symbol: symbol, timestamp: t,
                open: dec, high: dec + 1, low: dec - 1, close: dec,
                volume: 1_000_000
            ))
        }
        return bars
    }

    func testEndToEndSyntheticRun() async throws {
        let bars = syntheticBars(500)
        let config = BacktestConfig(
            startDate: bars.first!.timestamp,
            endDate: bars.last!.timestamp,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        let engine = BacktestEngine(
            config: config,
            strategy: CrossStrategy(symbol: Symbol("SYN")),
            bars: bars
        )
        let result = try await engine.run()

        XCTAssertEqual(result.snapshots.count, bars.count)
        XCTAssertGreaterThan(result.fills.count, 2)
        var holding: Decimal = 0
        for f in result.fills {
            holding += f.side == .buy ? f.quantity : -f.quantity
            XCTAssertGreaterThanOrEqual(holding, 0)
            XCTAssertLessThanOrEqual(holding, 1)
        }
        XCTAssertGreaterThan(result.finalEquity.amount, 0)
        XCTAssertGreaterThanOrEqual(result.maxDrawdown, 0)
        XCTAssertLessThanOrEqual(result.maxDrawdown, 1)
        XCTAssertTrue(result.sharpe.isFinite)
    }

    func testEngineSortsBarsAndRespectsDateRange() async throws {
        let allBars = syntheticBars(50)
        let startIdx = 15
        let endIdx = 35
        let config = BacktestConfig(
            startDate: allBars[startIdx].timestamp,
            endDate: allBars[endIdx].timestamp,
            initialCash: .usd(1000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        let engine = BacktestEngine(
            config: config,
            strategy: CrossStrategy(symbol: Symbol("SYN")),
            bars: allBars.shuffled()
        )
        let result = try await engine.run()
        XCTAssertEqual(result.snapshots.count, endIdx - startIdx + 1)
        for i in 1..<result.snapshots.count {
            XCTAssertLessThanOrEqual(
                result.snapshots[i - 1].timestamp,
                result.snapshots[i].timestamp
            )
        }
    }

    // MARK: - Corporate actions integration

    /// In-memory action source for tests — no file I/O needed.
    private struct InMemoryActionSource: CorporateActionSource {
        let events: [CorporateActionEvent]
        func actions(for symbol: Symbol, on date: Date) async -> [CorporateActionEvent] {
            events.filter { $0.symbol == symbol && $0.exDate == date }
        }
    }

    /// Strategy that buys once on the first bar and holds; verifies that
    /// position adjustments don't disrupt the equity curve.
    private struct BuyOnceHold: Strategy {
        let symbol: Symbol
        let quantity: Decimal
        private let bought = ActorBox()
        actor ActorBox { var done = false; func mark() { done = true } }
        func onBar(_ bar: Bar, context: StrategyContext) async throws {
            if await bought.done { return }
            try await context.buy(symbol, quantity: quantity)
            await bought.mark()
        }
    }

    func testEngineAppliesSplitToPosition() async throws {
        // Build bars where the price drops on the split day, mimicking real
        // raw market data on a 4-for-1 split. Pre-split: $100. Post-split: $25.
        var bars: [Bar] = []
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let oneDay: TimeInterval = 86_400
        for i in 0..<10 {
            let t = start.addingTimeInterval(Double(i) * oneDay)
            let price: Decimal = i < 5 ? 100 : 25
            bars.append(Bar(symbol: Symbol("SYN"), timestamp: t,
                            open: price, high: price + 1, low: price - 1, close: price,
                            volume: 1_000_000))
        }
        let splitDate = bars[5].timestamp
        let source = InMemoryActionSource(events: [
            CorporateActionEvent(symbol: Symbol("SYN"),
                                 exDate: splitDate,
                                 action: .split(ratio: 4))
        ])
        let config = BacktestConfig(
            startDate: bars.first!.timestamp,
            endDate: bars.last!.timestamp,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage(),
            corporateActions: source
        )
        let engine = BacktestEngine(
            config: config,
            strategy: BuyOnceHold(symbol: Symbol("SYN"), quantity: 10),
            bars: bars
        )
        let result = try await engine.run()
        // 10 shares bought day 1, split 4-for-1 on day 5 → 40 shares
        let finalQty = result.snapshots.last?.positions[Symbol("SYN")] ?? 0
        XCTAssertEqual(finalQty, 40)
        // With raw bars that drop on split day + position multiplier,
        // equity is continuous across the split: 10 × $100 = $1000 marked,
        // post-split 40 × $25 = $1000 marked. No phantom drawdown.
        let preIdx = result.snapshots.firstIndex { $0.timestamp == bars[4].timestamp }!
        let postIdx = result.snapshots.firstIndex { $0.timestamp == splitDate }!
        let preEquity = result.snapshots[preIdx].totalValue.amount
        let postEquity = result.snapshots[postIdx].totalValue.amount
        XCTAssertEqual(preEquity, postEquity)
    }

    func testEngineAppliesCashDividend() async throws {
        let bars = syntheticBars(10)
        let divDate = bars[3].timestamp
        let source = InMemoryActionSource(events: [
            CorporateActionEvent(symbol: Symbol("SYN"),
                                 exDate: divDate,
                                 action: .cashDividend(perShare: .usd(1)))
        ])
        let config = BacktestConfig(
            startDate: bars.first!.timestamp,
            endDate: bars.last!.timestamp,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage(),
            corporateActions: source
        )
        let engine = BacktestEngine(
            config: config,
            strategy: BuyOnceHold(symbol: Symbol("SYN"), quantity: 10),
            bars: bars
        )
        let result = try await engine.run()
        // 10 shares × $1 dividend = $10 cash credit on top of the buy-and-hold result.
        // Find the snapshot just before and at the dividend date — cash should jump $10.
        let beforeIdx = result.snapshots.firstIndex { $0.timestamp == bars[2].timestamp }!
        let atIdx = result.snapshots.firstIndex { $0.timestamp == divDate }!
        let cashBefore = result.snapshots[beforeIdx].cash[.usd] ?? 0
        let cashAt = result.snapshots[atIdx].cash[.usd] ?? 0
        XCTAssertEqual(cashAt - cashBefore, 10)
    }

    func testEngineWithoutActionSourceIsUnaffected() async throws {
        let bars = syntheticBars(10)
        let config = BacktestConfig(
            startDate: bars.first!.timestamp,
            endDate: bars.last!.timestamp,
            initialCash: .usd(10_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )
        let engine = BacktestEngine(
            config: config,
            strategy: BuyOnceHold(symbol: Symbol("SYN"), quantity: 10),
            bars: bars
        )
        let result = try await engine.run()
        let finalQty = result.snapshots.last?.positions[Symbol("SYN")] ?? 0
        XCTAssertEqual(finalQty, 10)  // unchanged — no actions applied
    }
}
