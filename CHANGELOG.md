# Changelog

All notable changes to Athena will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - TBD

The "Correctness Release". Closes two known v0.1 limitations: stop/stop-limit
order fills and corporate actions (splits + cash dividends). Additive,
non-breaking — existing v0.1 strategies continue to work unchanged.

### Added

- **AthenaBrokers**: stop and stop-limit order fill semantics in
  `SimulatedBroker`. Stops trigger when bar high/low crosses the stop
  price; gap-throughs fill at the open as worst-case. Stop-limits convert
  to a limit order at the limit price on trigger; gap-through-limit
  fills at open if open is on the favorable side, otherwise fills at
  limit if reached intra-bar.
- **AthenaCore**: `CorporateAction` enum (`.split(ratio:)`,
  `.cashDividend(perShare:)`), `CorporateActionEvent`,
  `CorporateActionSource` protocol, `NoCorporateActions` default.
  `Portfolio` gains `applySplit(symbol:ratio:)` (multiplies share count,
  divides per-share ACB; total cost basis preserved) and
  `applyCashDividend(symbol:perShare:)` (credits cash, no ACB change).
- **AthenaData**: `CSVCorporateActionSource` reading
  `Date,Symbol,Type,Value` schema with `split` and `cashDividend` types.
- **AthenaBacktest**: `BacktestConfig.corporateActions` parameter; engine
  applies actions at the start of each bar before broker fills and
  indicator updates.
- **ProtectiveStopExample**: demonstrates a buy-and-hold position with a
  10% protective stop using a GTC sell stop order.

### Design notes

- **Position adjustment, not price adjustment.** Bars stay raw; positions
  and cash adjust on ex-date. Strategies see real prices (matching live
  trading). If you use pre-adjusted bars (e.g. Yahoo "Adj Close"), simply
  omit a corporate-action source.

### Known limitations

- Spin-offs not yet supported (complex ACB allocation, deferred).
- Stock dividends and DRIP reinvestment not yet supported.
- Return-of-capital tax treatment deferred to a future TaxRegime release.
- Multi-currency FX adjustments on USD dividends deferred to multi-currency
  phase.
- No tax-aware accounting (deferred to a future release).
- macOS only in CI; Linux support is best-effort.
- Real market data is not committed; users provide their own.

## [0.1.0] - TBD

Initial public release.

### Added

- **AthenaCore**: `Symbol`, `Currency`, `Money`, `Bar`, `Order`, `OrderType`,
  `TimeInForce`, `Side`, `Fill`, `Position`, `Portfolio` (actor with
  ACB-tracked positions), `Clock` protocol with `SystemClock` and
  `BacktestClock`, `Strategy` protocol, `StrategyContext`, `Broker` protocol,
  `BrokerError`, `IndicatorProvider` protocol.
- **AthenaIndicators**: incremental `SMA`, `EMA`, `RSI` (Wilder's smoothing),
  `MACD`, `BollingerBands`, `ATR` (Wilder's smoothing). `IndicatorCache`
  actor exposing all six via `IndicatorProvider` with per-symbol isolation.
- **AthenaBrokers**: `SimulatedBroker` with next-bar-open market fills and
  intra-bar limit fills. `CommissionModel` implementations: `FreeCommission`,
  `FixedCommission`, `PerShareCommission`, `QuestradeStockCommission`.
  `SlippageModel` implementations: `NoSlippage`, `FixedBpsSlippage`,
  `VolumeImpactSlippage`.
- **AthenaData**: `CSVDataSource` for Yahoo Finance-format daily OHLCV CSVs
  with date-range filtering.
- **AthenaBacktest**: `BacktestEngine` actor wiring portfolio, broker,
  indicators, strategy, and clock. `BacktestResult` with `totalReturn`,
  `maxDrawdown`, and `sharpe`.
- **MACrossoverExample**: end-to-end example running a 50/200 simple moving
  average crossover strategy on SPY daily bars.
- **BuyAndHoldExample**: baseline benchmark — buy on bar 1, hold to the end.
- **RSIMeanReversionExample**: RSI(14) oversold/overbought entries on SPY.
- **BollingerBreakoutExample**: long on close above the upper Bollinger band,
  exit on a return to the middle band.
- **MACDSignalExample**: MACD(12,26,9) signal-line crossover, with state
  tracking so trades fire only on transitions.
- **CI**: GitHub Actions workflow running build, test, and ≥90% line
  coverage gate on every push and PR.
- **CD**: GitHub Actions workflow producing a release on every `v*.*.*` tag,
  with notes auto-extracted from this changelog.
- Apache 2.0 license, README, and CONTRIBUTING guide.

### Known limitations

- macOS only in CI; Linux support is best-effort.
- Real market data (`data/SPY.csv`) is not committed; users provide their own.

[Unreleased]: https://github.com/rives-cloud/Athena/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/rives-cloud/Athena/releases/tag/v0.2.0
[0.1.0]: https://github.com/rives-cloud/Athena/releases/tag/v0.1.0
