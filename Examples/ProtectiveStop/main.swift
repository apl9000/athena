import Foundation
import AthenaCore
import AthenaIndicators
import AthenaBrokers
import AthenaData
import AthenaBacktest

/// Buy-and-hold with a fixed protective stop-loss.
/// On the first bar, buy a fixed quantity and submit a sell stop at
/// (entry close * (1 - stopPct)). If the stop triggers, the position closes
/// and the strategy stays flat for the remainder of the backtest.
///
/// The point of this example is to show that stop-loss protection actually
/// works — a v0.1 backtest with the same logic would have silently held
/// through any drawdown, because stops did not fill.
struct ProtectiveStop: Strategy {
    let symbol: Symbol
    let positionSize: Decimal
    let stopPct: Decimal     // 0.10 = 10% trailing-from-entry stop
    private let entered = EnteredFlag()

    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }
        if await entered.value { return }

        try await context.buy(symbol, quantity: positionSize)
        let stopPrice = bar.close * (1 - stopPct)
        let stopOrder = Order(
            symbol: symbol, side: .sell, quantity: positionSize,
            type: .stop(stopPrice), tif: .gtc, createdAt: await context.clock.now
        )
        _ = try await context.broker.submit(stopOrder)
        await entered.set(true)
    }

    func onFinish(context: StrategyContext) async throws {
        if let pos = await context.portfolio.position(for: symbol), pos.quantity > 0 {
            try await context.sell(symbol, quantity: pos.quantity)
        }
    }
}

/// Tiny actor wrapper so the Sendable strategy can carry mutable entry state.
actor EnteredFlag {
    private var flag = false
    var value: Bool { flag }
    func set(_ v: Bool) { flag = v }
}

@main
struct ExampleRunner {
    static func main() async throws {
        let spy = Symbol("SPY")
        let dataURL = URL(fileURLWithPath: "./data/SPY.csv")
        let source = CSVDataSource(path: dataURL, symbol: spy)

        let iso = ISO8601DateFormatter()
        let start = iso.date(from: "2015-01-01T00:00:00Z")!
        let end = iso.date(from: "2024-12-31T00:00:00Z")!

        let bars = try await source.bars(for: spy, from: start, to: end)
        print("Loaded \(bars.count) bars for \(spy)")
        guard !bars.isEmpty else {
            print("No bars loaded — check ./data/SPY.csv exists.")
            return
        }

        let config = BacktestConfig(
            startDate: start,
            endDate: end,
            initialCash: .usd(100_000),
            commission: FreeCommission(currency: .usd),
            slippage: FixedBpsSlippage(bps: 2)
        )

        let strategy = ProtectiveStop(
            symbol: spy, positionSize: 100, stopPct: Decimal(string: "0.10")!
        )

        let engine = BacktestEngine(config: config, strategy: strategy, bars: bars)
        let result = try await engine.run()

        func pct(_ d: Decimal) -> String {
            String(format: "%.2f%%", NSDecimalNumber(decimal: d * 100).doubleValue)
        }

        print("""
        ── BACKTEST RESULT (Protective Stop, 10%) ─
        Initial equity:  \(result.initialEquity.amount) \(result.initialEquity.currency.rawValue)
        Final equity:    \(result.finalEquity.amount) \(result.finalEquity.currency.rawValue)
        Total return:    \(pct(result.totalReturn))
        Max drawdown:    \(pct(result.maxDrawdown))
        Sharpe (annual): \(String(format: "%.2f", result.sharpe))
        Fills:           \(result.fills.count)
        Snapshots:       \(result.snapshots.count)
        ───────────────────────────────────────────
        """)
    }
}
