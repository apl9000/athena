import Foundation
import AthenaCore
import AthenaIndicators
import AthenaBrokers
import AthenaData
import AthenaBacktest

/// A deliberately simple strategy: go long when fast SMA > slow SMA, flat otherwise.
/// This is not a money-maker. It is a vehicle for verifying that the engine does
/// what it claims — no look-ahead, correct ACB, realistic fills, accurate metrics.
struct MovingAverageCrossover: Strategy {
    let symbol: Symbol
    let fast: Int
    let slow: Int
    let positionSize: Decimal   // shares per entry

    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }

        guard
            let fastMA = await context.indicators.sma(symbol, period: fast),
            let slowMA = await context.indicators.sma(symbol, period: slow)
        else { return }

        let position = await context.portfolio.position(for: symbol)
        let isLong = (position?.quantity ?? 0) > 0

        if fastMA > slowMA, !isLong {
            try await context.buy(symbol, quantity: positionSize)
        } else if fastMA < slowMA, isLong, let pos = position {
            try await context.sell(symbol, quantity: pos.quantity)
        }
    }

    func onFinish(context: StrategyContext) async throws {
        // Close any open position so final equity isn't misleading.
        if let pos = await context.portfolio.position(for: symbol), pos.quantity > 0 {
            try await context.sell(symbol, quantity: pos.quantity)
        }
    }
}

@main
struct ExampleRunner {
    static func main() async throws {
        let spy = Symbol("SPY")

        // Supply your own SPY.csv in ./data/ — Yahoo Finance export works as-is.
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

        let strategy = MovingAverageCrossover(
            symbol: spy, fast: 50, slow: 200, positionSize: 100
        )

        let engine = BacktestEngine(config: config, strategy: strategy, bars: bars)
        let result = try await engine.run()

        func pct(_ d: Decimal) -> String {
            String(format: "%.2f%%", NSDecimalNumber(decimal: d * 100).doubleValue)
        }

        print("""

        ── BACKTEST RESULT ──────────────────
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
