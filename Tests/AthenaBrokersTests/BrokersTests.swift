import XCTest
import AthenaCore
@testable import AthenaBrokers

final class BrokersTests: XCTestCase {

    private func order(_ side: Side = .buy, qty: Decimal = 10, type: OrderType = .market) -> Order {
        Order(symbol: Symbol("SPY"), side: side, quantity: qty, type: type, createdAt: Date())
    }

    private func bar(open: Decimal = 100, high: Decimal = 101, low: Decimal = 99,
                     close: Decimal = 100, volume: Int = 1_000_000) -> Bar {
        Bar(
            symbol: Symbol("SPY"),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            open: open, high: high, low: low, close: close,
            volume: volume
        )
    }

    func testFreeCommission() {
        let c = FreeCommission().commission(for: order(), fillPrice: 100)
        XCTAssertEqual(c.amount, 0)
        XCTAssertEqual(c.currency, .cad)
        XCTAssertEqual(FreeCommission(currency: .usd).commission(for: order(), fillPrice: 100).currency, .usd)
    }

    func testFixedCommission() {
        let c = FixedCommission(amount: Decimal(string: "4.95")!).commission(for: order(), fillPrice: 100)
        XCTAssertEqual(c.amount, Decimal(string: "4.95"))
    }

    func testPerShareCommissionRaw() {
        let c = PerShareCommission(perShare: Decimal(string: "0.005")!, minimum: 1, maxPercent: Decimal(string: "0.01")!, currency: .usd)
        let result = c.commission(for: order(qty: 1000), fillPrice: 100)
        XCTAssertEqual(result.amount, 5)
    }

    func testPerShareCommissionFloor() {
        let c = PerShareCommission()
        let result = c.commission(for: order(qty: 1), fillPrice: 100)
        XCTAssertEqual(result.amount, 1)
    }

    func testPerShareCommissionCap() {
        let c = PerShareCommission()
        let result = c.commission(for: order(qty: 1000), fillPrice: Decimal(string: "0.10")!)
        XCTAssertEqual(result.amount, 1)
    }

    func testQuestradeCommissionUnderFloor() {
        let result = QuestradeStockCommission().commission(for: order(qty: 100), fillPrice: 50)
        XCTAssertEqual(result.amount, Decimal(string: "4.95"))
    }

    func testQuestradeCommissionInRange() {
        let result = QuestradeStockCommission().commission(for: order(qty: 700), fillPrice: 50)
        XCTAssertEqual(result.amount, 7)
    }

    func testQuestradeCommissionAtCap() {
        let result = QuestradeStockCommission().commission(for: order(qty: 5000), fillPrice: 50)
        XCTAssertEqual(result.amount, Decimal(string: "9.95"))
    }

    func testNoSlippageReturnsReference() {
        let p = NoSlippage().fillPrice(referencePrice: 100, order: order(), bar: bar())
        XCTAssertEqual(p, 100)
    }

    func testFixedBpsBuyAddsSellSubtracts() {
        let s = FixedBpsSlippage(bps: 100)
        let buy = s.fillPrice(referencePrice: 100, order: order(.buy), bar: bar())
        let sell = s.fillPrice(referencePrice: 100, order: order(.sell), bar: bar())
        XCTAssertEqual(buy, 101)
        XCTAssertEqual(sell, 99)
    }

    func testVolumeImpactZeroVolumeUsesGuard() {
        let s = VolumeImpactSlippage(baseBps: 2, impactFactor: 50)
        let p = s.fillPrice(referencePrice: 100, order: order(qty: 100), bar: bar(volume: 0))
        XCTAssertGreaterThan(p, 100)
    }

    func testVolumeImpactGrowsWithSize() {
        let s = VolumeImpactSlippage()
        let small = s.fillPrice(referencePrice: 100, order: order(qty: 10), bar: bar(volume: 1_000_000))
        let large = s.fillPrice(referencePrice: 100, order: order(qty: 100_000), bar: bar(volume: 1_000_000))
        XCTAssertGreaterThan(large, small)
    }

    func testVolumeImpactSellSubtracts() {
        let s = VolumeImpactSlippage()
        let p = s.fillPrice(referencePrice: 100, order: order(.sell, qty: 10), bar: bar(volume: 1_000_000))
        XCTAssertLessThan(p, 100)
    }

    func testSubmitAddsToOpenOrders() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(order())
        let open = try await broker.openOrders()
        XCTAssertEqual(open.count, 1)
    }

    func testCancelRemovesOrder() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        let o = try await broker.submit(order())
        try await broker.cancel(o.id)
        let open = try await broker.openOrders()
        XCTAssertEqual(open.count, 0)
    }

    func testMarketOrderFillsAtNextBarOpen() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(order(.buy, qty: 5))
        let fills = await broker.processBarOpen(bar(open: 100))
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.price, 100)
        let pos = await portfolio.position(for: Symbol("SPY"))
        XCTAssertEqual(pos?.quantity, 5)
    }

    func testLimitBuyFillsWhenBarTradesThrough() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(order(.buy, qty: 5, type: .limit(99)))
        let fills = await broker.processBarOpen(bar(open: 100, high: 101, low: 98))
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.price, 99)
    }

    func testLimitBuyDoesNotFillWhenBarMisses() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(order(.buy, qty: 5, type: .limit(95)))
        let fills = await broker.processBarOpen(bar(open: 100, high: 101, low: 99))
        XCTAssertEqual(fills.count, 0)
        let open = try await broker.openOrders()
        XCTAssertEqual(open.count, 0)
    }

    func testLimitSellFillsWhenBarTradesThrough() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        await portfolio.apply(Fill(orderId: UUID(), symbol: Symbol("SPY"), side: .buy,
                                   quantity: 10, price: 100, commission: .usd(0),
                                   slippageBps: 0, filledAt: Date()))
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .sell, quantity: 5,
                                          type: .limit(102), createdAt: Date()))
        let fills = await broker.processBarOpen(bar(open: 101, high: 103, low: 100))
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.price, 102)
    }

    func testStopBuyTriggersIntraBarFillsAtStop() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .buy, quantity: 1,
                                          type: .stop(105), createdAt: Date()))
        let fills = await broker.processBarOpen(bar(open: 100, high: 106, low: 99, close: 105))
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.price, 105)
    }

    func testStopBuyGapThroughFillsAtOpen() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .buy, quantity: 1,
                                          type: .stop(105), createdAt: Date()))
        // Bar gaps above the stop — worst-case fill at open
        let fills = await broker.processBarOpen(bar(open: 110, high: 112, low: 109, close: 111))
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.price, 110)
    }

    func testStopBuyNotTriggered() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .buy, quantity: 1,
                                          type: .stop(105), tif: .gtc, createdAt: Date()))
        let fills = await broker.processBarOpen(bar(open: 100, high: 104, low: 99, close: 103))
        XCTAssertEqual(fills.count, 0)
        let open = try await broker.openOrders()
        XCTAssertEqual(open.count, 1)  // GTC persists
    }

    func testStopSellTriggersIntraBarFillsAtStop() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        await portfolio.apply(Fill(orderId: UUID(), symbol: Symbol("SPY"), side: .buy,
                                   quantity: 10, price: 100, commission: .usd(0),
                                   slippageBps: 0, filledAt: Date()))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .sell, quantity: 5,
                                          type: .stop(95), createdAt: Date()))
        let fills = await broker.processBarOpen(bar(open: 99, high: 100, low: 94, close: 96))
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.price, 95)
    }

    func testStopSellGapThroughFillsAtOpen() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        await portfolio.apply(Fill(orderId: UUID(), symbol: Symbol("SPY"), side: .buy,
                                   quantity: 10, price: 100, commission: .usd(0),
                                   slippageBps: 0, filledAt: Date()))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .sell, quantity: 5,
                                          type: .stop(95), createdAt: Date()))
        // Gap down through stop — fill at open, not at the stop price
        let fills = await broker.processBarOpen(bar(open: 90, high: 91, low: 88, close: 89))
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.price, 90)
    }

    func testStopBuySlippageApplied() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: FixedBpsSlippage(bps: 100))
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .buy, quantity: 1,
                                          type: .stop(100), createdAt: Date()))
        let fills = await broker.processBarOpen(bar(open: 99, high: 101, low: 98, close: 100))
        XCTAssertEqual(fills.first?.price, 101)
        XCTAssertEqual(fills.first?.slippageBps, 100)
    }

    func testStopLimitBuyTriggersAndFillsAtLimit() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        // Triggered intra-bar: open below stop, high reaches stop, low ≤ limit
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .buy, quantity: 1,
                                          type: .stopLimit(stop: 105, limit: 106),
                                          createdAt: Date()))
        let fills = await broker.processBarOpen(bar(open: 100, high: 107, low: 105, close: 106))
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.price, 106)
    }

    func testStopLimitBuyTriggeredButLimitUnreachable() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        // Triggered (high ≥ stop) but bar's low never reaches limit
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .buy, quantity: 1,
                                          type: .stopLimit(stop: 105, limit: 105),
                                          tif: .gtc, createdAt: Date()))
        let fills = await broker.processBarOpen(bar(open: 100, high: 106, low: 105.5, close: 106))
        XCTAssertEqual(fills.count, 0)
        let open = try await broker.openOrders()
        XCTAssertEqual(open.count, 1)  // GTC persists
    }

    func testStopLimitBuyGapAboveLimitNoFill() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .buy, quantity: 1,
                                          type: .stopLimit(stop: 105, limit: 106),
                                          createdAt: Date()))
        // Gap above limit — unfillable
        let fills = await broker.processBarOpen(bar(open: 110, high: 112, low: 109, close: 111))
        XCTAssertEqual(fills.count, 0)
    }

    func testStopLimitBuyGapIntoTriggerZoneFillsAtOpen() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        // Open between stop and limit — fill at open (worst-case still within constraint)
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .buy, quantity: 1,
                                          type: .stopLimit(stop: 105, limit: 110),
                                          createdAt: Date()))
        let fills = await broker.processBarOpen(bar(open: 107, high: 109, low: 106, close: 108))
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.price, 107)
    }

    func testStopLimitSellTriggersAndFillsAtLimit() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        await portfolio.apply(Fill(orderId: UUID(), symbol: Symbol("SPY"), side: .buy,
                                   quantity: 10, price: 100, commission: .usd(0),
                                   slippageBps: 0, filledAt: Date()))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .sell, quantity: 5,
                                          type: .stopLimit(stop: 95, limit: 94),
                                          createdAt: Date()))
        let fills = await broker.processBarOpen(bar(open: 99, high: 100, low: 93, close: 95))
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills.first?.price, 94)
    }

    func testStopLimitSellGapBelowLimitNoFill() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        await portfolio.apply(Fill(orderId: UUID(), symbol: Symbol("SPY"), side: .buy,
                                   quantity: 10, price: 100, commission: .usd(0),
                                   slippageBps: 0, filledAt: Date()))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .sell, quantity: 5,
                                          type: .stopLimit(stop: 95, limit: 94),
                                          createdAt: Date()))
        // Gap below the limit — unfillable
        let fills = await broker.processBarOpen(bar(open: 90, high: 92, low: 88, close: 91))
        XCTAssertEqual(fills.count, 0)
    }

    func testGTCOrderPersistsWhenItDoesNotFill() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .buy, quantity: 1,
                                          type: .limit(50), tif: .gtc, createdAt: Date()))
        _ = await broker.processBarOpen(bar(open: 100, high: 101, low: 99))
        let open = try await broker.openOrders()
        XCTAssertEqual(open.count, 1)
    }

    func testOrdersForOtherSymbolsArePreserved() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .buy, quantity: 1, createdAt: Date()))
        _ = try await broker.submit(Order(symbol: Symbol("AAPL"), side: .buy, quantity: 1, createdAt: Date()))
        _ = await broker.processBarOpen(bar(open: 100))
        let open = try await broker.openOrders()
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.symbol, Symbol("AAPL"))
    }

    func testFillSlippageBpsRecorded() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: FixedBpsSlippage(bps: 100))
        _ = try await broker.submit(order(.buy, qty: 1))
        let fills = await broker.processBarOpen(bar(open: 100))
        XCTAssertEqual(fills.first?.price, 101)
        XCTAssertEqual(fills.first?.slippageBps, 100)
    }
}
