# Athena

**A Swift-native backtesting engine and quant library.** Incremental event-driven core, planned vectorized MLX fast path, broker and data adapters, and financial primitives that get the boring-but-critical things right — ACB, slippage, commission, look-ahead prevention.

Athena is the open-source foundation for [stonk.ninja](https://stonk.ninja), a Canadian-first portfolio cockpit. It works standalone.

## Status

**v0.1 — public launch.** The event-driven engine, core types, six indicators (SMA, EMA, RSI, MACD, Bollinger Bands, ATR), simulated broker with realistic commission/slippage models (Free, Fixed, PerShare, Questrade), and a CSV data source. CI enforces ≥ 90% line coverage on every push. The worked example is a dual moving-average crossover on SPY.

Planned for v0.2+:

- MLX-backed vectorized engine for parameter sweeps
- IBKR Web API and Alpaca broker adapters
- Stop / stop-limit order semantics
- Corporate action handling (splits, dividends, spin-offs)
- Multi-currency portfolio with FX provider
- Tax regimes (Canadian ACB, US wash-sale)

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
```

Each example prints initial/final equity, total return, max drawdown,
annualized Sharpe, and fill count, so you can compare strategies side-by-side
against the buy-and-hold baseline.

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
AthenaIndicators   SMA, EMA, RSI, MACD, Bollinger Bands, ATR + IndicatorCache
AthenaBrokers      Commission/slippage models, SimulatedBroker
AthenaData         DataSource protocol, CSV reader
AthenaBacktest     Event-driven engine, results, metrics
```

Each module is a separate library product so downstream code imports only what it needs.

## License

Apache 2.0. Use it, fork it, contribute back if you extend it.
