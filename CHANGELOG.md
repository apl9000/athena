# Changelog

All notable changes to Athena will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - TBD

The "MLX vectorized engine release". Adds the `AthenaMLX` module with
`MLXBacktestRunner` — a `BacktestRunner` that batches every
`VectorizableStrategy + NoTaxes + NoCorporateActions + single-symbol` cell
through a pure-Swift vectorized fill simulator instead of spinning up the
full actor-based event loop. Non-qualifying cells (non-`VectorizableStrategy`,
non-`NoTaxes`, non-`NoCorporateActions`, or multi-symbol) fall back silently
to `EventDrivenRunner` per cell. The v0.4 `Sweep` surface is unchanged;
switching to the fast path is one line.

### Added

- **AthenaCore**: `VectorizableStrategy` — opt-in protocol for strategies
  that can provide a `signals(for:) -> [Bool]` method. `true` = long
  (fully in); `false` = flat (fully out). A `false → true` transition
  triggers a buy at the next bar's open; `true → false` triggers a sell
  at the next bar's open. A transition on the final bar is not filled.
  The `Strategy` event methods remain fully available.
- **AthenaMLX**: New library product. `MLXBacktestRunner` conforming
  to `BacktestRunner` — a drop-in replacement for `EventDrivenRunner`
  in any `Sweep.init(runner:)` call. Routes `VectorizableStrategy +
  NoTaxes + NoCorporateActions + single-symbol` cells through
  `VectorizedFillSimulator`; all other cells fall back to
  `EventDrivenRunner` transparently.
- **AthenaMLX**: `VectorizedFillSimulator` — internal type that runs the
  full buy/sell/snapshot loop over a signal array without actor overhead.
  Supports `CommissionModel` and `SlippageModel` pass-through. Surfaces
  `VectorizedFillSimulatorError.signalCountMismatch` as a per-cell
  `SweepError` rather than a crash.
- **AthenaMLX**: Vectorized indicators — `VectorizedSMA`, `VectorizedEMA`,
  `VectorizedRSI` (Wilder's smoothed), `VectorizedBollingerBands`. All
  internal to `AthenaMLX`; exact `Decimal` parity with `AthenaIndicators`
  (SMA/EMA/RSI) and ≤ 1e-9 parity for BollingerBands (shared
  `Double`-bridged `sqrt`).
- **AthenaMLX**: `SignalFilter` protocol + `DebounceFilter` — post-process
  a strategy's boolean signal array before it reaches the fill simulator.
  `DebounceFilter(minBars:)` suppresses flips within `minBars` of the
  previous flip, reducing commission churn.
- **Tests/AthenaMLXTests**: Full test suite — `MLXBacktestRunnerTests`
  (conformance, single-cell, result-shape), `VectorizedFillSimulatorTests`
  (fill timing, quantity, slippage, commission, snapshots),
  `VectorizedIndicatorParityTests` (SMA/EMA/RSI/BB vs scalar),
  `MLXFallbackTests` (non-VectorizableStrategy and non-NoTaxes paths),
  `MLXRunnerValueEquivalenceTests` (cell-level and sweep-level equivalence),
  `MLXEquivalenceGateTests` (canonical golden-master CI fixture, pinned to
  `Xoshiro256**` seed `0xA1B2_C3D4`), `SignalFilterTests` (DebounceFilter).
- **MLXSweepExample**: Worked example demonstrating the one-line runner
  swap. Runs the same MA-crossover grid sweep twice — once with
  `EventDrivenRunner` and once with `MLXBacktestRunner` — printing
  timing and result tables side by side.

### Design notes

- **One-line swap.** Adopting `MLXBacktestRunner` requires only changing
  the `runner:` argument to `Sweep.init`. No strategy changes, no
  conditional compilation, no platform guards in user code.
- **Transparent fallback.** Cells that are not fast-path eligible
  (non-`VectorizableStrategy`, non-`NoTaxes`, non-`NoCorporateActions`,
  or multi-symbol) are silently routed to `EventDrivenRunner` per cell.
  The caller never needs to detect or handle the dispatch.
- **Platform agnostic.** `MLXBacktestRunner` is available on all platforms
  (macOS, iOS, Linux). The pure-Swift vectorized path runs everywhere; a
  future slice will add MLX GPU tensor dispatch behind
  `#if canImport(MLX)` on Apple Silicon for additional throughput.
- **Tax-regime sweeps fall back.** `CanadianACB` and `USWashSale` sweeps
  always use `EventDrivenRunner` per cell; the vectorized path is for
  `NoTaxes` only and does not support retroactive reconciliation.
- **Equivalence gate.** `MLXEquivalenceGateTests` pins vectorized sweep
  results against golden values from a seeded 300-bar fixture. CI fails
  if vectorized and event-driven fill structure diverges.

### Known limitations

- MLX GPU tensor dispatch is not yet active. The current vectorized path
  is a tight pure-Swift loop — faster than the actor event-loop for large
  sweeps, but not Apple-Silicon GPU-accelerated. A future v0.5 slice adds
  `#if canImport(MLX)` tensor dispatch.
- Long-only / flat positions only. Short positions, leverage, and sized
  positions are out of v0.5 scope.
- Vectorized indicator coverage: SMA, EMA, RSI, Bollinger Bands only.
  Strategies using MACD, ATR, or custom indicators fall back to the
  event-driven path automatically.
- Multi-symbol strategies are not fast-path eligible in v0.5.
- Walk-forward helpers and benchmark harnesses are out of v0.5 scope.

## [0.4.0] - TBD

The "parameter sweep release". Adds `AthenaSweep` — parallel parameter
sweeps over a grid or random sample of strategy configurations.

### Added

- **AthenaSweep**: `BacktestRunner` protocol (abstraction over running
  one strategy over one set of bars), `EventDrivenRunner` (default
  implementation wrapping `BacktestEngine`), `StrategyFactory` protocol
  + `ClosureStrategyFactory`, `ParameterSet` (a single point in
  parameter space), `AnySendableValue` (type-erased Sendable value),
  `ParameterAxis` (one named axis with discrete values),
  `ParameterSpace` (enumerated `ParameterSet`s — `.grid()` for
  Cartesian products, `.random()` for seeded random sampling),
  `Sweep` (parallel execution bounded by `concurrency`), `SweepResult`,
  `SweepError`.
- **ParameterSweepExample**: Demonstrates a 3×3 MA-crossover grid sweep
  on 1 000 synthetic daily bars, printing a return/drawdown/Sharpe/fills
  table and highlighting the best Sharpe combination.
- **AthenaSweepTests**: `ParameterSpaceTests` (grid, random, empty-axis
  edge cases) and `SweepTests` (concurrency, ordering, failure isolation).

### Design notes

- **Concurrency-bounded.** `Sweep` dispatches one backtest per
  `ParameterSet` using a task-group semaphore capped at
  `ProcessInfo.activeProcessorCount` to prevent memory thrashing on
  large grids.
- **Order-preserving.** `Sweep.run()` returns results in the same order
  as `space.sets` regardless of completion order.
- **Failure-isolated.** Per-cell errors land in `SweepResult.Outcome.failure`
  without aborting the rest of the sweep.

## [0.3.0] - TBD

The "Tax Realism Release". Adds pluggable tax accounting via a
`TaxRegime` protocol with two implementations: **Canadian ACB with the
superficial-loss rule** and **US FIFO with the wash-sale rule and
short-term/long-term classification**. Additive and back-compatible —
existing v0.2 strategies that don't set `taxRegime` get the `NoTaxes`
default and behave identically.

### Added

- **AthenaCore**: `TaxLot` (per-share basis with `washSaleAdjustment`),
  `Disposition` (per-sale realized P&L with `holdingPeriod`,
  `washSaleDisallowed`, and `taxableRealizedPnL`), `HoldingPeriod`
  (`.shortTerm`/`.longTerm` with strict > 365-day classification),
  `TaxYearSummary` (per-year per-currency aggregation with gross
  gain/loss, ST/LT split, and washed amounts), `TaxRegime` protocol
  with `dispose(fill:lots:)` and `reconcileDisallowance(...)` hooks,
  `NoTaxes` default. `Portfolio` gains `lots` (live FIFO inventory) and
  `lotHistory` (immutable audit log); both are populated on buy fills
  and consumed/scaled by sells and splits — only when a tax regime is
  set.
- **AthenaCore (TaxRegimes)**: `CanadianACB` (pooled basis at sale time
  per CRA convention + superficial-loss disallowance), `USWashSale`
  (FIFO lot consumption + ST/LT classification + wash-sale
  disallowance). Both regimes share a generic ±30-day reconciliation
  helper.
- **AthenaBrokers**: `SimulatedBroker.taxRegime` init parameter and
  `recordedDispositions()` accessor; provisional dispositions are
  recorded during the run and reconciled at end-of-backtest.
- **AthenaBacktest**: `BacktestConfig.taxRegime`. `BacktestResult`
  gains `dispositions: [Disposition]`, `taxYearSummaries:
  [TaxYearSummary]`, and `finalLots: [TaxLot]` (all default-empty for
  back-compat). Engine performs end-of-run reconciliation so
  forward-looking 30-day rules can adjust earlier dispositions.
- **TaxAwareExample**: demonstrates US wash-sale triggering with full
  loss disallowance and replacement-lot basis adjustment.

### Design notes

- **Forward-looking reconciliation.** Wash-sale and superficial-loss
  rules can't be settled at the time of sale because a replacement
  purchase 20 days later would retroactively disallow the loss. The
  broker records provisional dispositions; the engine asks the regime
  to reconcile them once the run ends and the full ±30-day window has
  materialized.
- **Lot work is conditional.** When `taxRegime` is `NoTaxes`, the
  Portfolio does zero lot work — v0.2 callers see no overhead and no
  behavioral change.
- **CanadianACB uses pooled basis** at the moment of sale (matching
  CRA convention and the existing `Position.avgCost` field), but still
  walks lots FIFO to attribute open-dates for reporting.
- **A lot can't replace itself.** Reconciliation skips lots whose
  `openDate` matches the disposition's `openDate` so the lot being
  sold isn't mistakenly counted as its own replacement.

### Known limitations

- FIFO only; specific-identification deferred.
- Tax events use the disposition currency; cross-currency reporting
  (USD dispositions → CAD home currency) deferred to multi-currency
  release.
- Single-portfolio model — spousal-account ACB pooling out of scope.
- Stock dividends, DRIP, and return-of-capital still deferred.

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
