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

    func testStopOrderDoesNotFillInV01() async throws {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let broker = SimulatedBroker(portfolio: portfolio,
                                     commissionModel: FreeCommission(currency: .usd),
                                     slippageModel: NoSlippage())
        _ = try await broker.submit(Order(symbol: Symbol("SPY"), side: .buy, quantity: 1,
                                          type: .stop(95), tif: .day, createdAt: Date()))
        let fills = await broker.processBarOpen(bar(open: 90))
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
