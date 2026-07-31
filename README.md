# Athena

**A Swift-native backtesting engine and quant library.** Incremental event-driven core, planned vectorized MLX fast path, broker and data adapters, and financial primitives that get the boring-but-critical things right — ACB, slippage, commission, look-ahead prevention.

Athena is an open-source Swift quant library. It works standalone.

## Status

**v0.5 — MLX vectorized engine.** Adds the `AthenaMLX` module with `MLXBacktestRunner` — a `BacktestRunner` that routes eligible cells through a pure-Swift vectorized fill simulator instead of the actor-based event loop, cutting per-cell overhead for large parameter sweeps. Cells where the strategy conforms to `VectorizableStrategy`, the config uses `NoTaxes` and `NoCorporateActions`, and the bar sequence covers a single symbol take the fast path; all others fall back silently to `EventDrivenRunner` per cell — no strategy changes, no platform guards, no API changes. The `VectorizableStrategy` protocol lets strategies express their signal logic as a single `[Bool]` array; vectorized SMA, EMA, RSI, and Bollinger Bands are included in `AthenaMLX`. A `SignalFilter` protocol (`DebounceFilter` built-in) lets you post-process signals before they reach the fill simulator. Switching from `EventDrivenRunner` to `MLXBacktestRunner` is a one-line change to `Sweep.init`. MLX GPU tensor dispatch (Apple Silicon) is planned for a future v0.5 slice; the current fast path runs on all platforms.

Builds on v0.4 (`AthenaSweep` module with `Sweep`, `ParameterSpace`, `ParameterAxis`, `BacktestRunner`), v0.3 (pluggable `TaxRegime`, `CanadianACB`, `USWashSale`), v0.2 (stop / stop-limit fills, splits, cash dividends), and the v0.1 foundation (event-driven engine, six indicators, simulated broker, CSV data source). CI enforces ≥ 90% line coverage on every push.

### v0.5 scope and limitations

- `MLXBacktestRunner` is available on all platforms. MLX GPU tensor dispatch (Apple Silicon) is planned for a future slice; the current fast path is pure Swift and runs on Linux/Intel too.
- Fast-path eligibility: strategy must conform to `VectorizableStrategy` AND `BacktestConfig` must use `NoTaxes` and `NoCorporateActions` and be single-symbol. Non-qualifying cells fall back to `EventDrivenRunner` transparently, with no API changes.
- Vectorized indicators in `AthenaMLX`: SMA, EMA, RSI (Wilder's), Bollinger Bands. Strategies using MACD, ATR, or custom indicators fall back to the event-driven path automatically.
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

// v0.5: vectorized fast path — one-line swap
let sweep = Sweep(
    factory: factory,
    runner: MLXBacktestRunner(),  // ← only change
    bars: bars,
    config: config,
    space: space
)
```

**Platform gating.** `MLXBacktestRunner` is available on all platforms (macOS,
iOS, Linux). The current fast path is pure Swift and runs everywhere. MLX GPU
tensor dispatch (Apple Silicon) is planned for a future v0.5 slice; non-MLX
platforms use the Swift vectorized path with identical results.

**Fallback behaviour.** `MLXBacktestRunner` evaluates these conditions on every
cell before deciding the dispatch path:

1. The strategy conforms to `VectorizableStrategy`.
2. The `BacktestConfig` uses `NoTaxes`.
3. The `BacktestConfig` uses `NoCorporateActions`.
4. The bar sequence covers at most one symbol.

If **any** condition is not met the cell is explicitly routed to
`EventDrivenRunner`. The result shape and numeric values are identical to a
direct `EventDrivenRunner` call — the fallback is fully transparent. Callers
never need to detect or handle the dispatch themselves.

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
AthenaMLX          MLXBacktestRunner (vectorized fast path), VectorizedFillSimulator,
                   vectorized SMA/EMA/RSI/BollingerBands, SignalFilter/DebounceFilter;
                   falls back to EventDrivenRunner for non-eligible cells (v0.5+)
```

Each module is a separate library product so downstream code imports only what it needs.

## License

Apache 2.0. Use it, fork it, contribute back if you extend it.
