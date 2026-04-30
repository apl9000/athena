import XCTest
@testable import AthenaCore

final class AthenaCoreTests: XCTestCase {

    // MARK: - Symbol

    func testSymbolNormalization() {
        XCTAssertEqual(Symbol("spy").ticker, "SPY")
        XCTAssertEqual(Symbol("RY.TO").description, "RY.TO")
        XCTAssertEqual(Symbol("RY", exchange: "TO").description, "RY.TO")
    }

    func testSymbolEqualityAndHashing() {
        XCTAssertEqual(Symbol("AAPL"), Symbol("aapl"))
        let set: Set<Symbol> = [Symbol("aapl"), Symbol("AAPL"), Symbol("MSFT")]
        XCTAssertEqual(set.count, 2)
    }

    func testSymbolCodableRoundTrip() throws {
        let s = Symbol("RY", exchange: "TO")
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(Symbol.self, from: data)
        XCTAssertEqual(decoded.ticker, "RY")
        XCTAssertEqual(decoded.exchange, "TO")
    }

    // MARK: - Money

    func testMoneyArithmetic() {
        let a = Money.cad(100)
        let b = Money.cad(50)
        XCTAssertEqual((a + b).amount, 150)
        XCTAssertEqual((a - b).amount, 50)
        XCTAssertEqual((a * 2).amount, 200)
    }

    func testMoneyConstructors() {
        XCTAssertEqual(Money.usd(42).currency, .usd)
        XCTAssertEqual(Money.cad(42).currency, .cad)
        XCTAssertEqual(Money(7, .eur).currency, .eur)
    }

    // MARK: - Side

    func testSideSign() {
        XCTAssertEqual(Side.buy.sign, 1)
        XCTAssertEqual(Side.sell.sign, -1)
    }

    // MARK: - Bar

    func testBarCodableRoundTrip() throws {
        let bar = Bar(
            symbol: Symbol("SPY"),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            open: 450, high: 452, low: 449, close: 451,
            volume: 1_000_000,
            adjustmentFactor: nil
        )
        let data = try JSONEncoder().encode(bar)
        let decoded = try JSONDecoder().decode(Bar.self, from: data)
        XCTAssertEqual(decoded, bar)
    }

    // MARK: - Order / Fill

    func testOrderDefaults() {
        let order = Order(
            symbol: Symbol("SPY"),
            side: .buy,
            quantity: 10,
            createdAt: Date()
        )
        XCTAssertEqual(order.tif, .day)
        XCTAssertEqual(order.status, .pending)
        if case .market = order.type {} else { XCTFail("expected market") }
    }

    func testOrderTypeEquality() {
        XCTAssertEqual(OrderType.limit(100), OrderType.limit(100))
        XCTAssertNotEqual(OrderType.limit(100), OrderType.limit(101))
        XCTAssertNotEqual(OrderType.market, OrderType.limit(100))
        let stopLimit = OrderType.stopLimit(stop: 95, limit: 94)
        XCTAssertEqual(stopLimit, OrderType.stopLimit(stop: 95, limit: 94))
    }

    func testFillNotional() {
        let fill = Fill(
            orderId: UUID(),
            symbol: Symbol("SPY"), side: .buy,
            quantity: 10, price: 100,
            commission: .cad(0), slippageBps: 0,
            filledAt: Date()
        )
        XCTAssertEqual(fill.notional, 1000)
    }

    // MARK: - Position

    func testPositionMarketValueAndPnL() {
        var pos = Position(symbol: Symbol("SPY"), currency: .usd)
        pos.quantity = 10
        pos.avgCost = 100
        XCTAssertEqual(pos.marketValue(at: 110).amount, 1100)
        XCTAssertEqual(pos.unrealizedPnL(at: 110).amount, 100)
        XCTAssertTrue(pos.isOpen)
        pos.quantity = 0
        XCTAssertFalse(pos.isOpen)
    }

    // MARK: - Portfolio

    func testPortfolioACBOnBuy() async {
        let portfolio = Portfolio(baseCurrency: .cad, initialCash: .cad(10_000))
        let spy = Symbol("SPY")

        await portfolio.apply(Fill(
            orderId: UUID(), symbol: spy, side: .buy,
            quantity: 10, price: 100,
            commission: .cad(0), slippageBps: 0, filledAt: Date()
        ))
        await portfolio.apply(Fill(
            orderId: UUID(), symbol: spy, side: .buy,
            quantity: 10, price: 120,
            commission: .cad(0), slippageBps: 0, filledAt: Date()
        ))

        let position = await portfolio.position(for: spy)
        XCTAssertEqual(position?.quantity, 20)
        XCTAssertEqual(position?.avgCost, 110)
        let cash = await portfolio.cashBalance(in: .cad)
        XCTAssertEqual(cash.amount, 7800)
    }

    func testPortfolioACBPreservedOnPartialSell() async {
        let portfolio = Portfolio(baseCurrency: .cad, initialCash: .cad(10_000))
        let spy = Symbol("SPY")
        await portfolio.apply(Fill(
            orderId: UUID(), symbol: spy, side: .buy,
            quantity: 20, price: 100,
            commission: .cad(0), slippageBps: 0, filledAt: Date()
        ))
        await portfolio.apply(Fill(
            orderId: UUID(), symbol: spy, side: .sell,
            quantity: 10, price: 150,
            commission: .cad(0), slippageBps: 0, filledAt: Date()
        ))
        let position = await portfolio.position(for: spy)
        XCTAssertEqual(position?.quantity, 10)
        XCTAssertEqual(position?.avgCost, 100)
    }

    func testPortfolioCashOnSellAndAvgCostResetWhenFlat() async {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(1000))
        let s = Symbol("AAPL")
        await portfolio.apply(Fill(
            orderId: UUID(), symbol: s, side: .buy,
            quantity: 5, price: 100,
            commission: .usd(0), slippageBps: 0, filledAt: Date()
        ))
        await portfolio.apply(Fill(
            orderId: UUID(), symbol: s, side: .sell,
            quantity: 5, price: 120,
            commission: .usd(0), slippageBps: 0, filledAt: Date()
        ))
        let pos = await portfolio.position(for: s)
        XCTAssertEqual(pos?.quantity, 0)
        XCTAssertEqual(pos?.avgCost, 0)
        let cash = await portfolio.cashBalance(in: .usd)
        XCTAssertEqual(cash.amount, 1100) // 1000 - 500 + 600
    }

    func testPortfolioApplyAppliesCommissionToCash() async {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(1000))
        await portfolio.apply(Fill(
            orderId: UUID(), symbol: Symbol("SPY"), side: .buy,
            quantity: 1, price: 100,
            commission: .usd(5), slippageBps: 0, filledAt: Date()
        ))
        let cash = await portfolio.cashBalance(in: .usd)
        XCTAssertEqual(cash.amount, 895) // 1000 - 100 - 5
    }

    func testPortfolioSnapshotAndEquity() async {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(1000))
        let s = Symbol("SPY")
        await portfolio.apply(Fill(
            orderId: UUID(), symbol: s, side: .buy,
            quantity: 5, price: 100,
            commission: .usd(0), slippageBps: 0, filledAt: Date()
        ))
        let snap = await portfolio.snapshot(
            at: Date(timeIntervalSince1970: 1000),
            marks: [s: 110]
        )
        // 500 cash + 5*110 = 1050
        XCTAssertEqual(snap.totalValue.amount, 1050)
        XCTAssertEqual(snap.positions[s], 5)
        let history = await portfolio.history
        XCTAssertEqual(history.count, 1)
        let equity = await portfolio.equity(marks: [s: 110])
        XCTAssertEqual(equity.amount, 1050)
    }

    func testPortfolioEquityIgnoresMissingMarks() async {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(1000))
        let s = Symbol("SPY")
        await portfolio.apply(Fill(
            orderId: UUID(), symbol: s, side: .buy,
            quantity: 5, price: 100,
            commission: .usd(0), slippageBps: 0, filledAt: Date()
        ))
        let equity = await portfolio.equity(marks: [:])
        XCTAssertEqual(equity.amount, 500) // just cash; position untracked
    }

    // MARK: - Clocks

    func testBacktestClockMonotonicity() async {
        let clock = BacktestClock(start: Date(timeIntervalSince1970: 0))
        await clock.advance(to: Date(timeIntervalSince1970: 100))
        let now = await clock.now
        XCTAssertEqual(now.timeIntervalSince1970, 100)
        try? await clock.sleep(until: Date(timeIntervalSince1970: 50)) // no-op
        let after = await clock.now
        XCTAssertEqual(after.timeIntervalSince1970, 100)
    }

    func testSystemClockNowAndPastSleepIsNoOp() async throws {
        let clock = SystemClock()
        let n1 = clock.now
        let n2 = clock.now
        XCTAssertGreaterThanOrEqual(n2.timeIntervalSince1970, n1.timeIntervalSince1970)
        // Past date: should return immediately without throwing
        try await clock.sleep(until: Date(timeIntervalSince1970: 0))
    }

    // MARK: - StrategyContext default extension

    func testStrategyDefaultLifecycleHooks() async throws {
        struct NoopStrategy: Strategy {
            func onBar(_ bar: Bar, context: StrategyContext) async throws {}
        }
        // Build a minimal ctx with stub broker/indicators just to call default hooks.
        // The defaults should be no-ops.
        actor StubBroker: Broker {
            func submit(_ order: Order) async throws -> Order { order }
            func cancel(_ orderId: UUID) async throws {}
            func openOrders() async throws -> [Order] { [] }
        }
        actor StubIndicators: IndicatorProvider {
            func sma(_ symbol: Symbol, period: Int) async -> Decimal? { nil }
            func ema(_ symbol: Symbol, period: Int) async -> Decimal? { nil }
            func rsi(_ symbol: Symbol, period: Int) async -> Decimal? { nil }
            func macd(_ symbol: Symbol, fast: Int, slow: Int, signal: Int)
                async -> (macd: Decimal, signal: Decimal, histogram: Decimal)? { nil }
            func bollinger(_ symbol: Symbol, period: Int, stddev: Decimal)
                async -> (upper: Decimal, middle: Decimal, lower: Decimal)? { nil }
            func atr(_ symbol: Symbol, period: Int) async -> Decimal? { nil }
        }
        let ctx = StrategyContext(
            portfolio: Portfolio(baseCurrency: .usd, initialCash: .usd(0)),
            broker: StubBroker(),
            clock: BacktestClock(start: Date()),
            indicators: StubIndicators()
        )
        try await NoopStrategy().onStart(context: ctx)
        try await NoopStrategy().onFinish(context: ctx)
    }

    // MARK: - Corporate actions

    func testApplySplitWholeRatio() async {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        await portfolio.apply(Fill(orderId: UUID(), symbol: Symbol("AAPL"), side: .buy,
                                   quantity: 10, price: 400, commission: .usd(0),
                                   slippageBps: 0, filledAt: Date()))
        await portfolio.applySplit(symbol: Symbol("AAPL"), ratio: 4)
        let pos = await portfolio.position(for: Symbol("AAPL"))
        XCTAssertEqual(pos?.quantity, 40)
        XCTAssertEqual(pos?.avgCost, 100)
        // Total cost basis preserved
        XCTAssertEqual((pos?.quantity ?? 0) * (pos?.avgCost ?? 0), 4_000)
    }

    func testApplySplitFractionalRatio() async {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        await portfolio.apply(Fill(orderId: UUID(), symbol: Symbol("XYZ"), side: .buy,
                                   quantity: 100, price: 30, commission: .usd(0),
                                   slippageBps: 0, filledAt: Date()))
        await portfolio.applySplit(symbol: Symbol("XYZ"), ratio: Decimal(string: "1.5")!)
        let pos = await portfolio.position(for: Symbol("XYZ"))
        XCTAssertEqual(pos?.quantity, 150)
        XCTAssertEqual(pos?.avgCost, 20)
    }

    func testApplySplitNoOpForMissingPosition() async {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        await portfolio.applySplit(symbol: Symbol("NONE"), ratio: 4)
        let pos = await portfolio.position(for: Symbol("NONE"))
        XCTAssertNil(pos)
    }

    func testApplyCashDividendCreditsCash() async {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        await portfolio.apply(Fill(orderId: UUID(), symbol: Symbol("KO"), side: .buy,
                                   quantity: 100, price: 60, commission: .usd(0),
                                   slippageBps: 0, filledAt: Date()))
        let cashBefore = await portfolio.cashBalance(in: .usd).amount
        await portfolio.applyCashDividend(symbol: Symbol("KO"),
                                          perShare: Money(Decimal(string: "0.46")!, .usd))
        let cashAfter = await portfolio.cashBalance(in: .usd).amount
        XCTAssertEqual(cashAfter - cashBefore, 46)
        // ACB unchanged
        let pos = await portfolio.position(for: Symbol("KO"))
        XCTAssertEqual(pos?.avgCost, 60)
    }

    func testApplyCashDividendNoOpForFlatPosition() async {
        let portfolio = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        await portfolio.applyCashDividend(symbol: Symbol("KO"), perShare: .usd(1))
        let cash = await portfolio.cashBalance(in: .usd).amount
        XCTAssertEqual(cash, 10_000)
    }

    func testCorporateActionEventTypes() {
        let split = CorporateAction.split(ratio: 4)
        let div = CorporateAction.cashDividend(perShare: .usd(1))
        XCTAssertNotEqual(split, div)
        let event = CorporateActionEvent(
            symbol: Symbol("AAPL"),
            exDate: Date(timeIntervalSince1970: 1_598_832_000),
            action: split
        )
        XCTAssertEqual(event.symbol, Symbol("AAPL"))
    }

    func testNoCorporateActionsReturnsEmpty() async {
        let source = NoCorporateActions()
        let events = await source.actions(for: Symbol("AAPL"), on: Date())
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Tax types

    func testHoldingPeriodBoundaryAt365Days() {
        let cal = Calendar(identifier: .gregorian)
        let open = Date(timeIntervalSince1970: 1_700_000_000)
        let exactly365 = cal.date(byAdding: .day, value: 365, to: open)!
        let day366 = cal.date(byAdding: .day, value: 366, to: open)!
        XCTAssertEqual(HoldingPeriod.classify(openDate: open, closeDate: exactly365), .shortTerm)
        XCTAssertEqual(HoldingPeriod.classify(openDate: open, closeDate: day366), .longTerm)
    }

    func testHoldingPeriodLeapYearMath() {
        let cal = Calendar(identifier: .gregorian)
        // Open during a leap year, close just past 365 days
        let open = cal.date(from: DateComponents(year: 2024, month: 1, day: 15))!
        let day366 = cal.date(byAdding: .day, value: 366, to: open)!
        XCTAssertEqual(HoldingPeriod.classify(openDate: open, closeDate: day366), .longTerm)
    }

    func testTaxLotTotalCost() {
        let lot = TaxLot(symbol: Symbol("ABC"), openDate: Date(), quantity: 100, costBasis: 25)
        XCTAssertEqual(lot.totalCost, 2500)
    }

    func testDispositionTaxableWithoutDisallowance() {
        let d = Disposition(
            symbol: Symbol("ABC"), openDate: Date(), closeDate: Date(),
            quantity: 10,
            proceeds: .usd(1100), costBasis: .usd(1000),
            realizedPnL: .usd(100), holdingPeriod: .shortTerm
        )
        XCTAssertEqual(d.taxableRealizedPnL.amount, 100)
    }

    func testDispositionTaxableWithDisallowance() {
        let d = Disposition(
            symbol: Symbol("ABC"), openDate: Date(), closeDate: Date(),
            quantity: 10,
            proceeds: .usd(900), costBasis: .usd(1000),
            realizedPnL: .usd(-100), holdingPeriod: .shortTerm,
            washSaleDisallowed: .usd(100)
        )
        // Disallowed loss is added back to taxable amount → 0
        XCTAssertEqual(d.taxableRealizedPnL.amount, 0)
    }

    // MARK: - TaxYearSummary

    func testTaxYearSummaryAggregates() {
        let cal = Calendar(identifier: .gregorian)
        let d2024 = cal.date(from: DateComponents(year: 2024, month: 6, day: 15))!
        let d2025 = cal.date(from: DateComponents(year: 2025, month: 3, day: 1))!
        let dispositions = [
            Disposition(symbol: Symbol("A"), openDate: d2024, closeDate: d2024,
                        quantity: 1, proceeds: .usd(150), costBasis: .usd(100),
                        realizedPnL: .usd(50), holdingPeriod: .shortTerm),
            Disposition(symbol: Symbol("B"), openDate: d2024, closeDate: d2024,
                        quantity: 1, proceeds: .usd(80), costBasis: .usd(100),
                        realizedPnL: .usd(-20), holdingPeriod: .longTerm),
            Disposition(symbol: Symbol("C"), openDate: d2025, closeDate: d2025,
                        quantity: 1, proceeds: .usd(200), costBasis: .usd(150),
                        realizedPnL: .usd(50), holdingPeriod: .longTerm),
        ]
        let summaries = TaxYearSummary.summarize(dispositions)
        XCTAssertEqual(summaries.count, 2)
        let y2024 = summaries.first { $0.year == 2024 }!
        XCTAssertEqual(y2024.grossGain, 50)
        XCTAssertEqual(y2024.grossLoss, -20)
        XCTAssertEqual(y2024.netRealized, 30)
        XCTAssertEqual(y2024.shortTermNet, 50)
        XCTAssertEqual(y2024.longTermNet, -20)
        let y2025 = summaries.first { $0.year == 2025 }!
        XCTAssertEqual(y2025.netRealized, 50)
        XCTAssertEqual(y2025.longTermNet, 50)
    }

    // MARK: - Portfolio with tax regime

    func testPortfolioOpensLotOnBuyWithRegime() async {
        let p = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let buy = Fill(orderId: UUID(), symbol: Symbol("AAPL"), side: .buy,
                       quantity: 10, price: 100,
                       commission: .usd(0), slippageBps: 0, filledAt: Date())
        await p.apply(buy, taxRegime: USWashSale())
        let lots = await p.lots[Symbol("AAPL")] ?? []
        XCTAssertEqual(lots.count, 1)
        XCTAssertEqual(lots[0].quantity, 10)
        XCTAssertEqual(lots[0].costBasis, 100)
    }

    func testPortfolioConsumesLotsFIFOOnSell() async {
        let p = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let cal = Calendar(identifier: .gregorian)
        let d1 = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let d2 = cal.date(byAdding: .day, value: 30, to: d1)!
        let d3 = cal.date(byAdding: .day, value: 60, to: d1)!
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("AAPL"), side: .buy,
                           quantity: 10, price: 100, commission: .usd(0),
                           slippageBps: 0, filledAt: d1), taxRegime: USWashSale())
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("AAPL"), side: .buy,
                           quantity: 10, price: 110, commission: .usd(0),
                           slippageBps: 0, filledAt: d2), taxRegime: USWashSale())
        let dispositions = await p.apply(
            Fill(orderId: UUID(), symbol: Symbol("AAPL"), side: .sell,
                 quantity: 15, price: 120, commission: .usd(0),
                 slippageBps: 0, filledAt: d3),
            taxRegime: USWashSale())
        XCTAssertEqual(dispositions.count, 2)
        // First disposition closes the full first lot (10 @ 100)
        XCTAssertEqual(dispositions[0].quantity, 10)
        XCTAssertEqual(dispositions[0].costBasis.amount, 1000)
        XCTAssertEqual(dispositions[0].realizedPnL.amount, 200)
        // Second closes 5 from the second lot (5 @ 110)
        XCTAssertEqual(dispositions[1].quantity, 5)
        XCTAssertEqual(dispositions[1].costBasis.amount, 550)
        XCTAssertEqual(dispositions[1].realizedPnL.amount, 50)
        // Remaining lot: 5 @ 110
        let remaining = await p.lots[Symbol("AAPL")] ?? []
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].quantity, 5)
    }

    func testPortfolioSplitAdjustsLots() async {
        let p = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("AAPL"), side: .buy,
                           quantity: 10, price: 400, commission: .usd(0),
                           slippageBps: 0, filledAt: Date()),
                      taxRegime: USWashSale())
        await p.applySplit(symbol: Symbol("AAPL"), ratio: 4)
        let lots = await p.lots[Symbol("AAPL")] ?? []
        XCTAssertEqual(lots.count, 1)
        XCTAssertEqual(lots[0].quantity, 40)
        XCTAssertEqual(lots[0].costBasis, 100)
        XCTAssertEqual(lots[0].quantity * lots[0].costBasis, 4000)  // total cost preserved
    }

    func testPortfolioWithoutRegimeKeepsNoLots() async {
        let p = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let buy = Fill(orderId: UUID(), symbol: Symbol("AAPL"), side: .buy,
                       quantity: 10, price: 100,
                       commission: .usd(0), slippageBps: 0, filledAt: Date())
        await p.apply(buy)  // default NoTaxes
        let lots = await p.lots[Symbol("AAPL")] ?? []
        XCTAssertTrue(lots.isEmpty)
    }

    // MARK: - USWashSale rule

    func testUSWashSaleDisallowsLossWithinWindow() async {
        // Buy 10 @ 100 day 0; sell 10 @ 80 day 30 (loss); buy 10 @ 85 day 45 (within 30 days)
        let cal = Calendar(identifier: .gregorian)
        let d0 = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let d30 = cal.date(byAdding: .day, value: 30, to: d0)!
        let d45 = cal.date(byAdding: .day, value: 45, to: d0)!
        let p = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let regime = USWashSale()
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 100, commission: .usd(0),
                           slippageBps: 0, filledAt: d0), taxRegime: regime)
        let provisional = await p.apply(
            Fill(orderId: UUID(), symbol: Symbol("X"), side: .sell,
                 quantity: 10, price: 80, commission: .usd(0),
                 slippageBps: 0, filledAt: d30), taxRegime: regime)
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 85, commission: .usd(0),
                           slippageBps: 0, filledAt: d45), taxRegime: regime)
        let history = await p.lotHistory
        let (adj, lots) = regime.reconcileDisallowance(
            dispositions: provisional, lotHistory: history)
        XCTAssertEqual(adj.count, 1)
        // Loss was -200; replacement lot covers all 10 shares → fully disallowed
        XCTAssertEqual(adj[0].washSaleDisallowed?.amount, 200)
        XCTAssertEqual(adj[0].taxableRealizedPnL.amount, 0)
        // Replacement lot basis bumped from 85 to 105 (per-share disallowance = 20)
        let replacement = lots.first { $0.openDate == d45 }!
        XCTAssertEqual(replacement.costBasis, 105)
        XCTAssertEqual(replacement.washSaleAdjustment, 20)
    }

    func testUSWashSalePartialReplacement() async {
        // Sell 10 at $20 loss → -200 total loss. Replacement buy is only 4 shares.
        // 4/10 of loss disallowed = -80. Remaining -120 stays.
        let cal = Calendar(identifier: .gregorian)
        let d0 = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let d10 = cal.date(byAdding: .day, value: 10, to: d0)!
        let d20 = cal.date(byAdding: .day, value: 20, to: d0)!
        let p = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let regime = USWashSale()
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 100, commission: .usd(0),
                           slippageBps: 0, filledAt: d0), taxRegime: regime)
        let provisional = await p.apply(
            Fill(orderId: UUID(), symbol: Symbol("X"), side: .sell,
                 quantity: 10, price: 80, commission: .usd(0),
                 slippageBps: 0, filledAt: d10), taxRegime: regime)
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 4, price: 85, commission: .usd(0),
                           slippageBps: 0, filledAt: d20), taxRegime: regime)
        let history = await p.lotHistory
        let (adj, _) = regime.reconcileDisallowance(
            dispositions: provisional, lotHistory: history)
        XCTAssertEqual(adj[0].washSaleDisallowed?.amount, 80)
        // Per-share disallowed = 20; 4 shares × 20 = 80
    }

    func testUSWashSaleOutsideWindowDoesNotDisallow() async {
        let cal = Calendar(identifier: .gregorian)
        let d0 = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let d30 = cal.date(byAdding: .day, value: 30, to: d0)!
        let d100 = cal.date(byAdding: .day, value: 100, to: d0)!  // > 30 days after
        let p = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let regime = USWashSale()
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 100, commission: .usd(0),
                           slippageBps: 0, filledAt: d0), taxRegime: regime)
        let provisional = await p.apply(
            Fill(orderId: UUID(), symbol: Symbol("X"), side: .sell,
                 quantity: 10, price: 80, commission: .usd(0),
                 slippageBps: 0, filledAt: d30), taxRegime: regime)
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 85, commission: .usd(0),
                           slippageBps: 0, filledAt: d100), taxRegime: regime)
        let history = await p.lotHistory
        let (adj, _) = regime.reconcileDisallowance(
            dispositions: provisional, lotHistory: history)
        XCTAssertNil(adj[0].washSaleDisallowed)
    }

    func testUSWashSaleGainNotAffected() async {
        let cal = Calendar(identifier: .gregorian)
        let d0 = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let d10 = cal.date(byAdding: .day, value: 10, to: d0)!
        let d20 = cal.date(byAdding: .day, value: 20, to: d0)!
        let p = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let regime = USWashSale()
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 100, commission: .usd(0),
                           slippageBps: 0, filledAt: d0), taxRegime: regime)
        let provisional = await p.apply(
            Fill(orderId: UUID(), symbol: Symbol("X"), side: .sell,
                 quantity: 10, price: 120, commission: .usd(0),
                 slippageBps: 0, filledAt: d10), taxRegime: regime)
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 125, commission: .usd(0),
                           slippageBps: 0, filledAt: d20), taxRegime: regime)
        let history = await p.lotHistory
        let (adj, _) = regime.reconcileDisallowance(
            dispositions: provisional, lotHistory: history)
        XCTAssertNil(adj[0].washSaleDisallowed)
        XCTAssertEqual(adj[0].realizedPnL.amount, 200)
    }

    func testUSWashSaleAcrossYearBoundary() async {
        // Loss in Dec 2024, replacement in Jan 2025 within 30 days
        let cal = Calendar(identifier: .gregorian)
        let buyDate = cal.date(from: DateComponents(year: 2024, month: 6, day: 1))!
        let lossDate = cal.date(from: DateComponents(year: 2024, month: 12, day: 20))!
        let replaceDate = cal.date(from: DateComponents(year: 2025, month: 1, day: 5))!
        let p = Portfolio(baseCurrency: .usd, initialCash: .usd(10_000))
        let regime = USWashSale()
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 100, commission: .usd(0),
                           slippageBps: 0, filledAt: buyDate), taxRegime: regime)
        let provisional = await p.apply(
            Fill(orderId: UUID(), symbol: Symbol("X"), side: .sell,
                 quantity: 10, price: 80, commission: .usd(0),
                 slippageBps: 0, filledAt: lossDate), taxRegime: regime)
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 85, commission: .usd(0),
                           slippageBps: 0, filledAt: replaceDate), taxRegime: regime)
        let history = await p.lotHistory
        let (adj, _) = regime.reconcileDisallowance(
            dispositions: provisional, lotHistory: history)
        XCTAssertEqual(adj[0].washSaleDisallowed?.amount, 200)
    }

    // MARK: - Canadian ACB regime

    func testCanadianACBPoolsBasis() async {
        // Buy 10 @ 100 then 10 @ 120 → pooled ACB = 110.
        // Sell 5 → basis = 5 × 110 = 550.
        let cal = Calendar(identifier: .gregorian)
        let d0 = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let d10 = cal.date(byAdding: .day, value: 100, to: d0)!  // outside wash window
        let d20 = cal.date(byAdding: .day, value: 200, to: d0)!
        let p = Portfolio(baseCurrency: .cad, initialCash: .cad(10_000))
        let regime = CanadianACB()
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 100, commission: .cad(0),
                           slippageBps: 0, filledAt: d0), taxRegime: regime)
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 120, commission: .cad(0),
                           slippageBps: 0, filledAt: d10), taxRegime: regime)
        let dispositions = await p.apply(
            Fill(orderId: UUID(), symbol: Symbol("X"), side: .sell,
                 quantity: 5, price: 130, commission: .cad(0),
                 slippageBps: 0, filledAt: d20), taxRegime: regime)
        XCTAssertEqual(dispositions.count, 1)
        XCTAssertEqual(dispositions[0].quantity, 5)
        XCTAssertEqual(dispositions[0].costBasis.amount, 550)
        XCTAssertEqual(dispositions[0].proceeds.amount, 650)
        XCTAssertEqual(dispositions[0].realizedPnL.amount, 100)
    }

    func testCanadianSuperficialLossRuleDisallows() async {
        // Same shape as US wash-sale test but using CanadianACB
        let cal = Calendar(identifier: .gregorian)
        let d0 = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let d30 = cal.date(byAdding: .day, value: 30, to: d0)!
        let d45 = cal.date(byAdding: .day, value: 45, to: d0)!
        let p = Portfolio(baseCurrency: .cad, initialCash: .cad(10_000))
        let regime = CanadianACB()
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 100, commission: .cad(0),
                           slippageBps: 0, filledAt: d0), taxRegime: regime)
        let provisional = await p.apply(
            Fill(orderId: UUID(), symbol: Symbol("X"), side: .sell,
                 quantity: 10, price: 80, commission: .cad(0),
                 slippageBps: 0, filledAt: d30), taxRegime: regime)
        await p.apply(Fill(orderId: UUID(), symbol: Symbol("X"), side: .buy,
                           quantity: 10, price: 85, commission: .cad(0),
                           slippageBps: 0, filledAt: d45), taxRegime: regime)
        let history = await p.lotHistory
        let (adj, lots) = regime.reconcileDisallowance(
            dispositions: provisional, lotHistory: history)
        XCTAssertEqual(adj[0].washSaleDisallowed?.amount, 200)
        let replacement = lots.first { $0.openDate == d45 }!
        XCTAssertEqual(replacement.costBasis, 105)
    }
}