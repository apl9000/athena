import Foundation
import AthenaCore
import AthenaIndicators
import AthenaBrokers
import AthenaData
import AthenaBacktest
import AthenaSweep

/// Demonstrates v0.4 parameter sweeps: run an MA-crossover strategy over
/// a small grid of (fast, slow) period combinations on synthetic data
/// and print the parameter set with the best annualized Sharpe.
///
/// Run with: `swift run ParameterSweepExample`
extension String {
    fileprivate func padded(_ n: Int) -> String {
        self.count >= n ? self + " " : self + String(repeating: " ", count: n - self.count)
    }
}

extension Int {
    fileprivate func padded(_ n: Int) -> String { String(self).padded(n) }
}

struct MACrossover: Strategy {
    let symbol: Symbol
    let fast: Int
    let slow: Int

    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }
        guard
            let fastMA = await context.indicators.sma(symbol, period: fast),
            let slowMA = await context.indicators.sma(symbol, period: slow)
        else { return }
        let pos = await context.portfolio.position(for: symbol)
        let qty = pos?.quantity ?? 0
        if fastMA > slowMA, qty == 0 {
            _ = try? await context.buy(symbol, quantity: 100)
        } else if fastMA < slowMA, qty > 0 {
            _ = try? await context.sell(symbol, quantity: qty)
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
        let symbol = Symbol("SYN")
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(year: 2020, month: 1, day: 1))!

        // Synthetic noisy uptrend so MA crossovers actually trigger.
        var bars: [Bar] = []
        var rng = Xoshiro256StarStar(seed: 12345)
        var price: Decimal = 100
        for i in 0..<1_000 {
            // Drift up ~0.05% per bar with ±2% noise.
            let r01 = Double(rng.next() % 10_000) / 10_000.0   // [0,1)
            let noise = Decimal(r01 * 0.04 - 0.02)             // ±2%
            price = price * (1 + Decimal(string: "0.0005")! + noise)
            if price < 1 { price = 1 }
            bars.append(Bar(
                symbol: symbol,
                timestamp: start.addingTimeInterval(Double(i) * 86_400),
                open: price, high: price * 1.005, low: price * 0.995, close: price,
                volume: 1_000_000
            ))
        }

        let config = BacktestConfig(
            startDate: bars.first!.timestamp,
            endDate: bars.last!.timestamp,
            initialCash: .usd(100_000),
            commission: FreeCommission(currency: .usd),
            slippage: NoSlippage()
        )

        let space = ParameterSpace.grid([
            .ints("fast", [5, 10, 20]),
            .ints("slow", [50, 100, 200]),
        ])

        let factory = ClosureStrategyFactory { params -> any Strategy in
            MACrossover(
                symbol: symbol,
                fast: params.int("fast") ?? 10,
                slow: params.int("slow") ?? 50
            )
        }

        print("Sweeping \(space.sets.count) parameter combinations across \(bars.count) bars…")
        let sweep = Sweep(factory: factory, bars: bars, config: config, space: space)
        let results = await sweep.run()

        func pct(_ d: Decimal) -> String {
            String(format: "%.2f%%", NSDecimalNumber(decimal: d * 100).doubleValue)
        }

        print("\n\(String(repeating: "─", count: 70))")
        print("fast  slow  return    drawdown  sharpe  fills")
        print(String(repeating: "─", count: 70))
        for r in results {
            guard let bt = r.backtest else {
                print("\(r.params) → ERROR")
                continue
            }
            let fast = r.params.int("fast") ?? 0
            let slow = r.params.int("slow") ?? 0
            let sharpe = String(format: "%.2f", bt.sharpe)
            print("\(fast.padded(5))\(slow.padded(6))\(pct(bt.totalReturn).padded(10))\(pct(bt.maxDrawdown).padded(10))\(sharpe.padded(8))\(bt.fills.count)")
        }

        if let best = results.compactMap({ r -> (ParameterSet, BacktestResult)? in
            guard let bt = r.backtest else { return nil }
            return (r.params, bt)
        }).max(by: { $0.1.sharpe < $1.1.sharpe }) {
            print("\nBest by Sharpe: \(best.0) → \(String(format: "%.2f", best.1.sharpe))")
        }
    }
}
