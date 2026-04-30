import Foundation
import AthenaCore
import AthenaIndicators
import AthenaBrokers
import AthenaData
import AthenaBacktest

/// Demonstrates v0.3 tax-aware backtesting with the US wash-sale regime.
///
/// Strategy: buy 100 shares on day 0; sell at a loss on day 30; buy 100
/// shares again on day 45 (within the 30-day wash-sale window). The
/// engine records a provisional disposition at the day-30 sell, detects
/// the day-45 replacement during end-of-run reconciliation, marks the
/// loss as fully disallowed, and bumps the replacement lot's basis by
/// the per-share disallowed amount.
///
/// Run with: `swift run TaxAwareExample`
struct WashSaleDemo: Strategy {
    let symbol: Symbol
    let sellOn: Date
    let rebuyOn: Date
    private let state = DemoState()

    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }
        let phase = await state.phase
        switch phase {
        case .initial:
            try await context.buy(symbol, quantity: 100)
            await state.advance(to: .bought)
        case .bought where bar.timestamp >= sellOn:
            try await context.sell(symbol, quantity: 100)
            await state.advance(to: .sold)
        case .sold where bar.timestamp >= rebuyOn:
            try await context.buy(symbol, quantity: 100)
            await state.advance(to: .rebought)
        default:
            break
        }
    }
}

actor DemoState {
    enum Phase { case initial, bought, sold, rebought }
    private(set) var phase: Phase = .initial
    func advance(to p: Phase) { phase = p }
}

@main
struct ExampleRunner {
    static func main() async throws {
        let symbol = Symbol("DEMO")
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let oneDay: TimeInterval = 86_400

        // Synthetic price series:
        //   Day 0–29:  100 (buy at 100)
        //   Day 30–44: 80  (sell at loss → -2000)
        //   Day 45+:   85  (rebuy within wash window → loss disallowed)
        var bars: [Bar] = []
        for i in 0..<60 {
            let p: Decimal
            if i < 30 { p = 100 }
            else if i < 45 { p = 80 }
            else { p = 85 }
            bars.append(Bar(
                symbol: symbol,
                timestamp: start.addingTimeInterval(Double(i) * oneDay),
                open: p, high: p + 1, low: p - 1, close: p,
                volume: 1_000_000
            ))
        }

        let sellOn = start.addingTimeInterval(30 * oneDay)
        let rebuyOn = start.addingTimeInterval(45 * oneDay)

        let config = BacktestConfig(
            startDate: bars.first!.timestamp,
            endDate: bars.last!.timestamp,
            initialCash: .usd(50_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage(),
            taxRegime: USWashSale()
        )

        let strategy = WashSaleDemo(symbol: symbol, sellOn: sellOn, rebuyOn: rebuyOn)
        let engine = BacktestEngine(config: config, strategy: strategy, bars: bars)
        let result = try await engine.run()

        print("""
        ── TAX-AWARE BACKTEST (US wash-sale) ──
        Initial equity:  \(result.initialEquity.amount) USD
        Final equity:    \(result.finalEquity.amount) USD
        Fills:           \(result.fills.count)
        Dispositions:    \(result.dispositions.count)
        ───────────────────────────────────────
        """)

        for (i, d) in result.dispositions.enumerated() {
            print("""
            Disposition #\(i + 1):
              symbol:               \(d.symbol.ticker)
              opened:               \(d.openDate)
              closed:               \(d.closeDate)
              quantity:             \(d.quantity)
              proceeds:             \(d.proceeds.amount) \(d.proceeds.currency)
              cost basis:           \(d.costBasis.amount) \(d.costBasis.currency)
              realized P&L:         \(d.realizedPnL.amount) \(d.realizedPnL.currency)
              wash-sale disallowed: \(d.washSaleDisallowed.map { "\($0.amount) \($0.currency)" } ?? "—")
              taxable P&L:          \(d.taxableRealizedPnL.amount) \(d.taxableRealizedPnL.currency)
              holding period:       \(d.holdingPeriod)
            """)
        }

        print("\n── YEAR SUMMARIES ──")
        for s in result.taxYearSummaries {
            print("""
            Year \(s.year) (\(s.currency)):
              gross gain:         \(s.grossGain)
              gross loss:         \(s.grossLoss)
              wash-sale disallow: \(s.washSaleDisallowed)
              net realized:       \(s.netRealized)
              short-term net:     \(s.shortTermNet)
              long-term net:      \(s.longTermNet)
            """)
        }

        print("\n── FINAL LOTS (with wash-sale basis adjustments) ──")
        for lot in result.finalLots where lot.quantity > 0 {
            print("""
            \(lot.symbol.ticker) opened \(lot.openDate):
              qty:                  \(lot.quantity)
              cost basis/share:     \(lot.costBasis)
              wash-sale adjustment: \(lot.washSaleAdjustment)
            """)
        }
    }
}
