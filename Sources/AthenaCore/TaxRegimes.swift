import Foundation

/// Helper FIFO consumption shared by both real regimes.
/// Consumes `quantity` shares from the front of `lots`, returning the
/// (lot, qtyConsumed) pairs. Lots reduced to zero are kept in place with
/// quantity 0; the Portfolio filters them after the call.
internal func consumeFIFO(
    quantity: Decimal,
    lots: inout [TaxLot]
) -> [(TaxLot, Decimal)] {
    var remaining = quantity
    var consumed: [(TaxLot, Decimal)] = []
    for i in lots.indices {
        if remaining <= 0 { break }
        let available = lots[i].quantity
        if available <= 0 { continue }
        let take = min(available, remaining)
        consumed.append((lots[i], take))
        lots[i].quantity = available - take
        remaining -= take
    }
    return consumed
}

/// Build a per-lot disposition. Holding period uses the open lot's date.
internal func makeDisposition(
    fill: Fill,
    lot: TaxLot,
    quantity: Decimal
) -> Disposition {
    let proceeds = quantity * fill.price
    let basis = quantity * lot.costBasis
    let pnl = proceeds - basis
    return Disposition(
        symbol: fill.symbol,
        openDate: lot.openDate,
        closeDate: fill.filledAt,
        quantity: quantity,
        proceeds: Money(proceeds, fill.commission.currency),
        costBasis: Money(basis, fill.commission.currency),
        realizedPnL: Money(pnl, fill.commission.currency),
        holdingPeriod: HoldingPeriod.classify(openDate: lot.openDate, closeDate: fill.filledAt)
    )
}

/// Number of calendar days between two dates (signed).
internal func daysBetween(_ a: Date, _ b: Date) -> Int {
    Calendar(identifier: .gregorian)
        .dateComponents([.day], from: a, to: b).day ?? 0
}

/// Generic 30-day-window disallowance reconciler used by both wash-sale
/// (US) and superficial-loss (Canadian) rules. They differ only in label;
/// the math is identical.
///
/// Algorithm: for each loss disposition, find replacement lots opened
/// within ±30 calendar days of the close date that haven't yet absorbed
/// disallowance. Allocate the disallowed amount per-share to those lots,
/// up to the replacement quantity. Returns the adjusted dispositions and
/// the adjusted lots.
internal func reconcileLossDisallowance(
    dispositions: [Disposition],
    lotHistory: [TaxLot]
) -> ([Disposition], [TaxLot]) {
    var lots = lotHistory
    var sortedDisp = dispositions.enumerated().map { ($0, $1) }
    // Process losses in chronological close-date order so earlier losses
    // claim replacement lots first (deterministic).
    sortedDisp.sort { $0.1.closeDate < $1.1.closeDate }

    var disallowedRemainingPerLot: [UUID: Decimal] = [:]
    for lot in lots { disallowedRemainingPerLot[lot.id] = lot.quantity }

    var adjusted = dispositions
    for (origIdx, d) in sortedDisp {
        guard d.realizedPnL.amount < 0 else { continue }
        var lossRemaining = -d.realizedPnL.amount   // positive
        var qtyToMatch = d.quantity
        for i in lots.indices {
            if qtyToMatch <= 0 || lossRemaining <= 0 { break }
            let lot = lots[i]
            guard lot.symbol == d.symbol else { continue }
            // A lot can't replace itself — skip the lot(s) being disposed.
            if lot.openDate == d.openDate { continue }
            // Replacement window: opened within ±30 days of the close date.
            let days = daysBetween(d.closeDate, lot.openDate)
            guard days >= -30 && days <= 30 else { continue }
            // Only count quantity not already absorbed.
            let availableQty = disallowedRemainingPerLot[lot.id] ?? 0
            if availableQty <= 0 { continue }
            let matchQty = min(availableQty, qtyToMatch)
            // Per-share loss disallowed = lossRemaining / qtyToMatch
            let perShareDisallowed = lossRemaining / qtyToMatch
            let amountDisallowed = perShareDisallowed * matchQty
            // Bump replacement lot's basis
            lots[i].costBasis += perShareDisallowed
            lots[i].washSaleAdjustment += perShareDisallowed
            disallowedRemainingPerLot[lot.id] = availableQty - matchQty
            // Track on the disposition
            let prev = adjusted[origIdx].washSaleDisallowed?.amount ?? 0
            adjusted[origIdx].washSaleDisallowed = Money(
                prev + amountDisallowed,
                d.realizedPnL.currency
            )
            qtyToMatch -= matchQty
            lossRemaining -= amountDisallowed
        }
    }
    return (adjusted, lots)
}

// MARK: - CanadianACB

/// Canadian regime — pooled (averaged) cost basis with the superficial-loss
/// rule (Income Tax Act s.54). Identical 30-day window math to US wash-sale,
/// applied to the same security; CRA's "identical property" rule is treated
/// as exact symbol match for this engine.
///
/// Disposition basis uses the **pooled ACB at time of sale**, not per-lot
/// FIFO basis — this matches the CRA convention and keeps the result
/// consistent with the Portfolio's existing `Position.avgCost` field. We
/// still walk lots FIFO so we can attribute open-dates for reporting.
public struct CanadianACB: TaxRegime {
    public init() {}

    public func dispose(fill: Fill, lots: inout [TaxLot]) -> [Disposition] {
        // Pooled ACB at time of sale.
        let totalQty = lots.reduce(Decimal(0)) { $0 + $1.quantity }
        guard totalQty > 0 else { return [] }
        let totalCost = lots.reduce(Decimal(0)) { $0 + ($1.quantity * $1.costBasis) }
        let pooledBasis = totalCost / totalQty
        let consumed = consumeFIFO(quantity: fill.quantity, lots: &lots)
        return consumed.map { (lot, qty) in
            let proceeds = qty * fill.price
            let basis = qty * pooledBasis
            let pnl = proceeds - basis
            return Disposition(
                symbol: fill.symbol,
                openDate: lot.openDate,
                closeDate: fill.filledAt,
                quantity: qty,
                proceeds: Money(proceeds, fill.commission.currency),
                costBasis: Money(basis, fill.commission.currency),
                realizedPnL: Money(pnl, fill.commission.currency),
                holdingPeriod: HoldingPeriod.classify(openDate: lot.openDate, closeDate: fill.filledAt)
            )
        }
    }

    public func reconcileDisallowance(
        dispositions: [Disposition],
        lotHistory: [TaxLot]
    ) -> (dispositions: [Disposition], lots: [TaxLot]) {
        let (adj, lots) = reconcileLossDisallowance(dispositions: dispositions, lotHistory: lotHistory)
        return (adj, lots)
    }
}

// MARK: - USWashSale

/// US regime — strict FIFO lot consumption (specific identification not
/// supported in v0.3). Holding period > 365 days is long-term. Wash-sale
/// rule (IRC s.1091) disallows losses within 30 days before or after a
/// replacement purchase.
public struct USWashSale: TaxRegime {
    public init() {}

    public func dispose(fill: Fill, lots: inout [TaxLot]) -> [Disposition] {
        let consumed = consumeFIFO(quantity: fill.quantity, lots: &lots)
        return consumed.map { (lot, qty) in makeDisposition(fill: fill, lot: lot, quantity: qty) }
    }

    public func reconcileDisallowance(
        dispositions: [Disposition],
        lotHistory: [TaxLot]
    ) -> (dispositions: [Disposition], lots: [TaxLot]) {
        let (adj, lots) = reconcileLossDisallowance(dispositions: dispositions, lotHistory: lotHistory)
        return (adj, lots)
    }
}
