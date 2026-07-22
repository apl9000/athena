# Athena

**A Swift-native backtesting engine and quant library.** Incremental event-driven core, planned vectorized MLX fast path, broker and data adapters, and financial primitives that get the boring-but-critical things right — ACB, slippage, commission, look-ahead prevention.

Athena is an open-source Swift quant library. It works standalone.

## Status

**v0.5 — MLX runner seam + explicit fallback paths.** Adds the `AthenaMLX` module with `MLXBacktestRunner` — an alternative `BacktestRunner` that is the entry point for the MLX-backed vectorized fast path on Apple Silicon. The runner now contains the explicit dispatch decision: cells that conform to `VectorizableStrategy` _and_ use `NoTaxes` are routed to the fast path; all other cells are transparently forwarded to `EventDrivenRunner`. In the current slice the fast path still delegates to `EventDrivenRunner` so results are numerically identical and non-MLX platforms build cleanly; real tensor dispatch is gated behind `#if canImport(MLX)` and lands in a later slice. The `VectorizableStrategy` opt-in protocol is available for strategies that want to express their signal logic as a single vectorized pass. Switching from `EventDrivenRunner` to `MLXBacktestRunner` is a one-line change to `Sweep.init` — no strategy changes needed.

Builds on v0.4 (`AthenaSweep` module with `Sweep`, `ParameterSpace`, `ParameterAxis`, `BacktestRunner`), v0.3 (pluggable `TaxRegime`, `CanadianACB`, `USWashSale`), v0.2 (stop / stop-limit fills, splits, cash dividends), and the v0.1 foundation (event-driven engine, six indicators, simulated broker, CSV data source). CI enforces ≥ 90% line coverage on every push.

### v0.5 scope and limitations

- `MLXBacktestRunner` is available on all platforms. The MLX tensor fast path (later slices) requires Apple Silicon (macOS / iOS).
- Fast-path eligibility (later slices): strategy must conform to `VectorizableStrategy` AND `BacktestConfig` must use `NoTaxes`. Non-qualifying strategies and tax-regime sweeps fall back to `EventDrivenRunner` per cell — transparently, with no API changes.
- Vectorized indicators in v0.5: SMA, EMA, RSI, Bollinger Bands. MACD and ATR are not vectorized; strategies using them fall back automatically.
- Long-only / flat positions only. Short positions, sized positions, and leverage are out of v0.5 scope.
- Tax-regime sweeps (`CanadianACB`, `USWashSale`) always fall back to `EventDrivenRunner`; the vectorized path is for `NoTaxes` only.

Planned for v0.6+:

- IBKR Web API and Alpaca broker adapters
- Spin-offs, stock dividends, DRIP reinvestment
- Multi-currency portfolio with FX provider
- Specific-identification lot selection
- Cross-currency tax reporting

## Quick start

```bash
git clone https://github.com/rives-cloud/Athena
cd Athena
swift build
swift test

# Fetch SPY daily history (any source that produces Date,Open,High,Low,Close,Volume)
# and drop it at ./data/SPY.csv. The Python one-liner below uses yfinance:
#   pip install yfinance
#   python -c "import yfinance as yf; df=yf.download('SPY',start='2015-01-01',auto_adjust=False,progress=False); df.columns=df.columns.get_level_values(0); df.reset_index().assign(Date=lambda d: d['Date'].dt.strftime('%Y-%m-%d')).to_csv('data/SPY.csv',index=False)"

# Then run any of the worked examples:
swift run MACrossoverExample
swift run BuyAndHoldExample
swift run RSIMeanReversionExample
swift run BollingerBreakoutExample
swift run MACDSignalExample
swift run ProtectiveStopExample
swift run TaxAwareExample
swift run ParameterSweepExample  # v0.4: parameter sweep with EventDrivenRunner
swift run MLXSweepExample        # v0.5: same sweep with both runners side-by-side
```

Each example prints initial/final equity, total return, max drawdown,
annualized Sharpe, and fill count, so you can compare strategies side-by-side
against the buy-and-hold baseline.

## MLXBacktestRunner — adopting the v0.5 fast path

`MLXBacktestRunner` is a drop-in replacement for `EventDrivenRunner`. The only
required change is the `runner:` argument to `Sweep.init`:

```swift
import AthenaMLX

// v0.4: event-driven (default)
let sweep = Sweep(factory: factory, bars: bars, config: config, space: space)

// v0.5: MLX runner seam — one-line swap, identical results in slice 1
let sweep = Sweep(
    factory: factory,
    runner: MLXBacktestRunner(),  // ← only change
    bars: bars,
    config: config,
    space: space
)
```

**Platform gating.** `MLXBacktestRunner` is available on all platforms. The
MLX tensor fast path (added in later v0.5 slices) requires Apple Silicon.
On Intel macOS, Linux, and other non-Apple-Silicon platforms the runner
falls back to `EventDrivenRunner` per cell — no build errors, no strategy
changes, and results are identical.

**Fallback behaviour.** `MLXBacktestRunner` evaluates two conditions on every
cell before deciding the dispatch path:

1. The strategy conforms to `VectorizableStrategy`.
2. The `BacktestConfig` uses `NoTaxes` (tax-regime sweeps always fall back).

If **either** condition is not met the cell is explicitly routed to
`EventDrivenRunner`. The result shape and numeric values are identical to a
direct `EventDrivenRunner` call — the fallback is fully transparent. Callers
never need to detect or handle the dispatch themselves.

In the current slice the fast-path branch (`VectorizableStrategy` + `NoTaxes`)
also delegates to `EventDrivenRunner` while real tensor dispatch is pending;
it is gated behind `#if canImport(MLX)` and will be filled in once `mlx-swift`
is added as a conditional macOS / iOS dependency.

**`VectorizableStrategy` opt-in.** Strategies that want to participate in
the fast path implement `signals(for:)`:

```swift
struct SMACrossover: Strategy, VectorizableStrategy {
    let fast: Int
    let slow: Int

    func onBar(_ bar: Bar, context: StrategyContext) async throws { ... }

    // Called once per cell; returns a Bool array the same length as bars.
    // true = long (fully in), false = flat (fully out).
    // A false→true transition buys at the next bar's open; true→false sells.
    // A transition on the final bar has no next open and is not filled.
    func signals(for bars: [Bar]) -> [Bool] {
        // compute vectorized SMA signals here
        return bars.map { _ in true }  // placeholder
    }
}
```

**Vectorized indicators (v0.5).** SMA, EMA, RSI, and Bollinger Bands have
vectorized implementations inside `AthenaMLX`. Strategies using only these
four indicators are fast-path eligible. MACD and ATR fall back automatically.

## Development

```bash
make test       # swift test
make coverage   # runs scripts/coverage.sh — fails if line coverage < 90%
make build      # swift build -c release
```

## Design principles

1. **The same Strategy runs in backtest, paper, and live.** Only the Clock, DataSource, and Broker differ.
2. **Decimal for money.** Always. FP drift on cash is not a tradeoff.
3. **Realistic fills by default.** Commission and slippage are non-zero out of the box. Backtests that ignore these are stories, not evidence.
4. **Actors for concurrency safety.** Portfolio and SimulatedBroker are actors; strategies are Sendable structs.
5. **Protocol-oriented.** CommissionModel, SlippageModel, Broker, DataSource, Clock, Strategy, Indicator — each a protocol with reference implementations. Swap what you need.

## Module structure

```
AthenaCore         Types, Portfolio, Clock, Strategy + Broker/Indicator protocols
                   + VectorizableStrategy (v0.5 opt-in for MLX fast path)
AthenaIndicators   SMA, EMA, RSI, MACD, Bollinger Bands, ATR + IndicatorCache
AthenaBrokers      Commission/slippage models, SimulatedBroker
AthenaData         DataSource protocol, CSV reader
AthenaBacktest     Event-driven engine, results, metrics
AthenaSweep        Parallel parameter sweeps — BacktestRunner seam, Sweep,
                   ParameterSpace, ParameterAxis, EventDrivenRunner (v0.4+)
AthenaMLX          MLXBacktestRunner — fast-path entry point for Apple Silicon
                   parameter sweeps; falls back to EventDrivenRunner (v0.5+)
```

Each module is a separate library product so downstream code imports only what it needs.

## License

Apache 2.0. Use it, fork it, contribute back if you extend it.
