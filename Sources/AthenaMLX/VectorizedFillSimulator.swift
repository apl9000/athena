import Foundation
import AthenaCore
import AthenaBrokers
import AthenaBacktest

// MARK: - VectorizedFillSimulator
//
// Lightweight, value-semantic fill simulation for the AthenaMLX fast path.
//
// This type is *internal* to AthenaMLX and must not appear in Athena's
// public API. It implements the same observable fill semantics as
// BacktestEngine/SimulatedBroker for the v0.5 long/flat scope:
//
// - signals[i] = desired position AFTER the strategy processes bar[i]
//   (based on bar[i].close).  The fill that acts on that decision lands at
//   bar[i+1].open — identical to the event-driven "submit then fill next
//   bar" loop.
// - Going long  (false → true): buy floor(availableCash / fillPrice) shares.
// - Going flat  (true → false): sell the entire position.
// - A transition on the final bar has no next open and is never filled.
//
// v0.5 constraints (out of scope for later slices):
// - Single-symbol bars only.
// - NoTaxes regime; the caller is responsible for checking this.
// - Whole-share quantities only.
// - Commission currency is assumed to match the base (initialCash) currency.

struct VectorizedFillSimulator {

    // MARK: - Public result type

    struct SimulationResult {
        let fills: [Fill]
        let snapshots: [PortfolioSnapshot]
        let finalEquity: Money
    }

    // MARK: - Entry point

    /// Simulate a long/flat signal sequence against a bar array.
    ///
    /// - Parameters:
    ///   - symbol:      The traded symbol (used to populate fills).
    ///   - signals:     Per-bar position intent; must equal `bars.count`.
    ///   - bars:        Pre-filtered and sorted bar array (caller's responsibility).
    ///   - initialCash: Starting portfolio cash.
    ///   - commission:  Commission model (default `FreeCommission`).
    ///   - slippage:    Slippage model (default `FixedBpsSlippage(bps: 2)`).
    /// - Returns: Fills, per-bar snapshots, and final equity.
    func simulate(
        symbol: Symbol,
        signals: [Bool],
        bars: [Bar],
        initialCash: Money,
        commission: any CommissionModel,
        slippage: any SlippageModel
    ) -> SimulationResult {
        precondition(
            signals.count == bars.count,
            "VectorizedFillSimulator: signals.count (\(signals.count)) != bars.count (\(bars.count))"
        )
        guard !bars.isEmpty else {
            return SimulationResult(fills: [], snapshots: [], finalEquity: initialCash)
        }

        let currency = initialCash.currency
        var cash: Decimal = initialCash.amount
        var positionQty: Decimal = 0
        var fills: [Fill] = []
        var snapshots: [PortfolioSnapshot] = []

        // executedSignal: the position we are ACTUALLY holding right now.
        // Starts as false (flat) before the first bar.
        var executedSignal = false

        for i in bars.indices {
            let bar = bars[i]

            // ── Step 1: Execute fill at bar[i].open for the transition
            //    that signals[i-1] requested.
            //
            //    When i == 0 there is no previous signal, so no fill is
            //    possible at the opening of the first bar.
            if i > 0 {
                let pendingSignal = signals[i - 1]
                if pendingSignal != executedSignal {
                    if pendingSignal {
                        // false → true: enter long
                        if let fill = executeBuy(
                            symbol: symbol, bar: bar,
                            cash: &cash, positionQty: &positionQty,
                            commission: commission, slippage: slippage,
                            currency: currency
                        ) {
                            fills.append(fill)
                        }
                    } else {
                        // true → false: exit to flat
                        if let fill = executeSell(
                            symbol: symbol, bar: bar,
                            cash: &cash, positionQty: &positionQty,
                            commission: commission, slippage: slippage,
                            currency: currency
                        ) {
                            fills.append(fill)
                        }
                    }
                    executedSignal = pendingSignal
                }
            }

            // ── Step 2: Snapshot at bar[i].close (mark-to-market).
            let totalValue = cash + positionQty * bar.close
            let snap = PortfolioSnapshot(
                timestamp: bar.timestamp,
                totalValue: Money(totalValue, currency),
                cash: [currency: cash],
                positions: positionQty > 0 ? [symbol: positionQty] : [:]
            )
            snapshots.append(snap)
        }

        // Final equity: remaining cash + open position marked to last close.
        let lastClose = bars.last!.close
        let finalEquity = Money(cash + positionQty * lastClose, currency)
        return SimulationResult(fills: fills, snapshots: snapshots, finalEquity: finalEquity)
    }

    // MARK: - Private helpers

    /// Execute a long-entry fill at `bar.open`.
    ///
    /// Buys as many whole shares as the available cash permits after
    /// accounting for slippage and commission. Returns `nil` when cash
    /// is insufficient for at least one share.
    private func executeBuy(
        symbol: Symbol,
        bar: Bar,
        cash: inout Decimal,
        positionQty: inout Decimal,
        commission: any CommissionModel,
        slippage: any SlippageModel,
        currency: Currency
    ) -> Fill? {
        guard cash > 0 else { return nil }

        // ── Pass 1: estimate fill price and quantity without commission.
        //
        // We use qty=1 for the first slippage probe because:
        //   * FixedBpsSlippage ignores quantity → exact result immediately.
        //   * VolumeImpactSlippage scales with sqrt(qty/volume) → the
        //     estimated fill price is slightly low, but the second pass
        //     corrects it.
        let probe1 = syntheticOrder(symbol: symbol, side: .buy, qty: 1, at: bar.timestamp)
        let fillPrice1 = slippage.fillPrice(referencePrice: bar.open, order: probe1, bar: bar)
        guard fillPrice1 > 0 else { return nil }

        var qty = floorDecimal(cash / fillPrice1)
        guard qty >= 1 else { return nil }

        // ── Pass 2: apply slippage and commission for the estimated qty.
        //
        // This pass handles VolumeImpactSlippage (qty-dependent) and
        // PerShareCommission (qty-dependent) accurately.
        let probe2 = syntheticOrder(symbol: symbol, side: .buy, qty: qty, at: bar.timestamp)
        let fillPrice2 = slippage.fillPrice(referencePrice: bar.open, order: probe2, bar: bar)
        guard fillPrice2 > 0 else { return nil }

        let comm2 = commission.commission(for: probe2, fillPrice: fillPrice2)
        let cashAfterComm = cash - comm2.amount
        guard cashAfterComm > 0 else { return nil }

        qty = floorDecimal(cashAfterComm / fillPrice2)
        guard qty >= 1 else { return nil }

        // ── Finalise: compute exact fill price and commission for the
        //    adjusted quantity, then verify total cost fits in cash.
        let finalOrder = syntheticOrder(symbol: symbol, side: .buy, qty: qty, at: bar.timestamp)
        let finalFillPrice = slippage.fillPrice(referencePrice: bar.open, order: finalOrder, bar: bar)
        let finalComm = commission.commission(for: finalOrder, fillPrice: finalFillPrice)
        let totalCost = qty * finalFillPrice + finalComm.amount
        guard totalCost <= cash else { return nil }

        cash -= totalCost
        positionQty = qty

        let slippageBps = bar.open > 0
            ? ((finalFillPrice - bar.open) / bar.open) * 10_000
            : 0

        return Fill(
            orderId: UUID(),
            symbol: symbol,
            side: .buy,
            quantity: qty,
            price: finalFillPrice,
            commission: finalComm,
            slippageBps: slippageBps,
            filledAt: bar.timestamp
        )
    }

    /// Execute a flat-exit fill at `bar.open`. Sells the entire position.
    /// Returns `nil` when there is nothing to sell.
    private func executeSell(
        symbol: Symbol,
        bar: Bar,
        cash: inout Decimal,
        positionQty: inout Decimal,
        commission: any CommissionModel,
        slippage: any SlippageModel,
        currency: Currency
    ) -> Fill? {
        guard positionQty > 0 else { return nil }

        let qty = positionQty
        let sellOrder = syntheticOrder(symbol: symbol, side: .sell, qty: qty, at: bar.timestamp)
        let fillPrice = slippage.fillPrice(referencePrice: bar.open, order: sellOrder, bar: bar)
        let comm = commission.commission(for: sellOrder, fillPrice: fillPrice)

        let proceeds = qty * fillPrice - comm.amount
        cash += proceeds
        positionQty = 0

        let slippageBps = bar.open > 0
            ? ((fillPrice - bar.open) / bar.open) * 10_000
            : 0

        return Fill(
            orderId: UUID(),
            symbol: symbol,
            side: .sell,
            quantity: qty,
            price: fillPrice,
            commission: comm,
            slippageBps: slippageBps,
            filledAt: bar.timestamp
        )
    }

    // MARK: - Utilities

    /// Build a minimal Order for passing to CommissionModel / SlippageModel.
    private func syntheticOrder(
        symbol: Symbol,
        side: Side,
        qty: Decimal,
        at timestamp: Date
    ) -> Order {
        Order(
            symbol: symbol,
            side: side,
            quantity: qty,
            type: .market,
            tif: .day,
            createdAt: timestamp
        )
    }

    /// Floor a Decimal to the nearest integer (rounds toward zero for
    /// positive values, which is the desired "whole shares" behaviour).
    private func floorDecimal(_ value: Decimal) -> Decimal {
        var result = Decimal()
        var input = value
        NSDecimalRound(&result, &input, 0, .down)
        return result
    }
}
