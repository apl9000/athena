# Changelog

All notable changes to Athena will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- **CI**: GitHub Actions workflow running build, test, and ≥90% line
  coverage gate on every push and PR.
- **CD**: GitHub Actions workflow producing a release on every `v*.*.*` tag,
  with notes auto-extracted from this changelog.
- Apache 2.0 license, README, and CONTRIBUTING guide.

### Known limitations

- Stop and stop-limit orders are accepted but not yet filled (returns nil).
- No corporate actions (splits, dividends, spin-offs).
- No tax-aware accounting (deferred to v0.2).
- macOS only in CI; Linux support is best-effort.
- Real market data (`data/SPY.csv`) is not committed; users provide their own.

[Unreleased]: https://github.com/rives-cloud/Athena/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rives-cloud/Athena/releases/tag/v0.1.0
