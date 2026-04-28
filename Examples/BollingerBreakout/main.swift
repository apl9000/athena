import Foundation
import AthenaCore
import AthenaIndicators
import AthenaBrokers
import AthenaData
import AthenaBacktest

/// Volatility-breakout: enter long when close pierces the upper Bollinger band,
/// exit when it falls back to the middle band (the SMA).
struct BollingerBreakout: Strategy {
    let symbol: Symbol
    let period: Int
    let stddev: Decimal
    let positionSize: Decimal

    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }
        guard let bb = await context.indicators.bollinger(symbol, period: period, stddev: stddev) else { return }

        let position = await context.portfolio.position(for: symbol)
        let qty = position?.quantity ?? 0

        if bar.close > bb.upper, qty == 0 {
            try await context.buy(symbol, quantity: positionSize)
        } else if bar.close < bb.middle, qty > 0 {
            try await context.sell(symbol, quantity: qty)
        }
    }

    func onFinish(context: StrategyContext) async throws {
        if let pos = await context.portfolio.position(for: symbol), pos.quantity > 0 {
            try await context.sell(symbol, quantity: pos.quantity)
        }
    }
}

@main
struct ExampleRunner {
    static func main() async throws {
        let spy = Symbol("SPY")
        let source = CSVDataSource(path: URL(fileURLWithPath: "./data/SPY.csv"), symbol: spy)

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
            startDate: start, endDate: end,
            initialCash: .usd(100_000),
            commission: FreeCommission(currency: .usd),
            slippage: FixedBpsSlippage(bps: 2)
        )

        let strategy = BollingerBreakout(
            symbol: spy, period: 20, stddev: 2, positionSize: 100
        )
        let engine = BacktestEngine(config: config, strategy: strategy, bars: bars)
        let result = try await engine.run()

        func pct(_ d: Decimal) -> String {
            String(format: "%.2f%%", NSDecimalNumber(decimal: d * 100).doubleValue)
        }

        print("""
        ── BACKTEST RESULT (BollingerBreakout) ─
        Initial equity:  \(result.initialEquity.amount) \(result.initialEquity.currency.rawValue)
        Final equity:    \(result.finalEquity.amount) \(result.finalEquity.currency.rawValue)
        Total return:    \(pct(result.totalReturn))
        Max drawdown:    \(pct(result.maxDrawdown))
        Sharpe (annual): \(String(format: "%.2f", result.sharpe))
        Fills:           \(result.fills.count)
        Snapshots:       \(result.snapshots.count)
        ─────────────────────────────────────
        """)
    }
}
