import Foundation
import AthenaCore
import AthenaIndicators
import AthenaBrokers
import AthenaData
import AthenaBacktest
import AthenaSweep
import AthenaMLX

/// Demonstrates the v0.5 MLX vectorized engine.
///
/// The same MA-crossover parameter sweep is run twice:
///   1. With `EventDrivenRunner` (the v0.4 default)
///   2. With `MLXBacktestRunner` (the v0.5 vectorized fast path)
///
/// Results are equivalent for strategies that fall back to `EventDrivenRunner`
/// (like `MACrossover` below, which does not conform to `VectorizableStrategy`).
/// The only code change is the `runner:` argument passed to `Sweep.init`.
///
/// Run with: `swift run MLXSweepExample`
///
/// ## Platform note
/// `MLXBacktestRunner` is available on all platforms Athena supports.
/// The current fast path is a pure-Swift vectorized fill simulator;
/// strategies that conform to `VectorizableStrategy` and use `NoTaxes`
/// run through it automatically. All others fall back to `EventDrivenRunner`
/// per cell — no strategy changes needed, no broken builds.
/// MLX GPU tensor dispatch (Apple Silicon) is planned for a future slice.

// MARK: - Helpers

private extension String {
    func padded(_ n: Int) -> String {
        count >= n ? self + " " : self + String(repeating: " ", count: n - count)
    }
}

private extension Int {
    func padded(_ n: Int) -> String { String(self).padded(n) }
}

private func pct(_ d: Decimal) -> String {
    String(format: "%.2f%%", NSDecimalNumber(decimal: d * 100).doubleValue)
}

private func printTable(_ results: [SweepResult]) {
    let line = String(repeating: "─", count: 68)
    print(line)
    print("fast  slow  return    drawdown  sharpe  fills")
    print(line)
    for r in results {
        guard let bt = r.backtest else {
            print("\(r.params) → ERROR")
            continue
        }
        let fast = r.params.int("fast") ?? 0
        let slow = r.params.int("slow") ?? 0
        let sharpe = String(format: "%.2f", bt.sharpe)
        print(
            "\(fast.padded(5))\(slow.padded(6))"
            + "\(pct(bt.totalReturn).padded(10))"
            + "\(pct(bt.maxDrawdown).padded(10))"
            + "\(sharpe.padded(8))\(bt.fills.count)"
        )
    }
    print(line)
}

private func bestBySharpe(_ results: [SweepResult]) -> (ParameterSet, BacktestResult)? {
    results.compactMap { r -> (ParameterSet, BacktestResult)? in
        guard let bt = r.backtest else { return nil }
        return (r.params, bt)
    }.max { $0.1.sharpe < $1.1.sharpe }
}

// MARK: - Strategy

private struct MACrossover: Strategy {
    let symbol: Symbol
    let fast: Int
    let slow: Int

    func onBar(_ bar: Bar, context: StrategyContext) async throws {
        guard bar.symbol == symbol else { return }
        guard
            let fastMA = await context.indicators.sma(symbol, period: fast),
            let slowMA = await context.indicators.sma(symbol, period: slow)
        else { return }
        let qty = await context.portfolio.position(for: symbol)?.quantity ?? 0
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

// MARK: - Main

@main
struct MLXSweepExample {
    static func main() async throws {
        let symbol = Symbol("SYN")

        // Synthetic noisy uptrend — 1 000 daily bars starting 2020-01-01.
        var bars: [Bar] = []
        var rng = Xoshiro256StarStar(seed: 12345)
        var price: Decimal = 100
        let start = Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: 2020, month: 1, day: 1))!
        for i in 0..<1_000 {
            let r01 = Double(rng.next() % 10_000) / 10_000.0
            let noise = Decimal(r01 * 0.04 - 0.02)
            price = price * (1 + Decimal(string: "0.0005")! + noise)
            if price < 1 { price = 1 }
            bars.append(Bar(
                symbol: symbol,
                timestamp: start.addingTimeInterval(Double(i) * 86_400),
                open: price,
                high: price * Decimal(string: "1.005")!,
                low: price * Decimal(string: "0.995")!,
                close: price,
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

        print("""
        Athena v0.5 — MLX sweep demo
        ─────────────────────────────────────────────────────────────────────
        Strategy : MA-crossover (fast × slow grid)
        Grid     : \(space.sets.count) combinations
        Bars     : \(bars.count) daily bars (synthetic uptrend)

        """)

        // ── Run 1: EventDrivenRunner (v0.4 default) ─────────────────────────
        print("── EventDrivenRunner ──")
        let t0ed = Date()
        let edResults = await Sweep(
            factory: factory,
            runner: EventDrivenRunner(),   // ← v0.4 default
            bars: bars,
            config: config,
            space: space
        ).run()
        let edTime = Date().timeIntervalSince(t0ed)
        printTable(edResults)
        if let best = bestBySharpe(edResults) {
            print("Best by Sharpe: \(best.0) → \(String(format: "%.2f", best.1.sharpe))")
        }
        print(String(format: "Wall-clock: %.3fs\n", edTime))

        // ── Run 2: MLXBacktestRunner (v0.5 fast-path entry point) ───────────
        print("── MLXBacktestRunner ──")
        let t0mlx = Date()
        let mlxResults = await Sweep(
            factory: factory,
            runner: MLXBacktestRunner(),   // ← one-line swap
            bars: bars,
            config: config,
            space: space
        ).run()
        let mlxTime = Date().timeIntervalSince(t0mlx)
        printTable(mlxResults)
        if let best = bestBySharpe(mlxResults) {
            print("Best by Sharpe: \(best.0) → \(String(format: "%.2f", best.1.sharpe))")
        }
        print(String(format: "Wall-clock: %.3fs\n", mlxTime))

        // ── Result comparison ────────────────────────────────────────────────
        print("── Result comparison ──")
        var identical = true
        for (ed, mlx) in zip(edResults, mlxResults) {
            guard let edBT = ed.backtest, let mlxBT = mlx.backtest else { continue }
            if edBT.totalReturn != mlxBT.totalReturn || edBT.fills.count != mlxBT.fills.count {
                identical = false
                print("  MISMATCH at \(ed.params):")
                print("    EventDriven: return=\(pct(edBT.totalReturn)) fills=\(edBT.fills.count)")
                print("    MLX        : return=\(pct(mlxBT.totalReturn)) fills=\(mlxBT.fills.count)")
            }
        }
        if identical {
            print("  ✓ All \(edResults.count) cells: results identical across both runners.")
        }

        print("""

        Notes
        ─────
        • Switching to MLXBacktestRunner is the only code change (runner: argument).
        • MACrossover (above) does not conform to VectorizableStrategy, so both
          runners produce identical results via EventDrivenRunner fallback.
        • Strategies that conform to VectorizableStrategy and use NoTaxes take the
          pure-Swift vectorized fast path — no actor overhead, tighter inner loop.
        • Non-qualifying strategies and non-NoTaxes configs always fall back to
          EventDrivenRunner per cell — no strategy changes, no broken builds.
        • Tax-regime sweeps (non-NoTaxes) fall back to EventDrivenRunner per cell.
        • Vectorized indicators in AthenaMLX: SMA, EMA, RSI (Wilder's), Bollinger Bands.
        • MLX GPU tensor dispatch (Apple Silicon) is planned for a future v0.5 slice.
        """)
    }
}
