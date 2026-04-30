import Foundation

// MARK: - Holding period

/// Holding-period classification for realized gains. Used by US tax regimes
/// to split short-term vs long-term capital gains. Canadian regimes do not
/// distinguish but the field is reported uniformly so consumers can ignore it.
public enum HoldingPeriod: String, Sendable, Codable, Hashable {
    case shortTerm  // <= 365 days
    case longTerm   // > 365 days

    /// US convention: held strictly more than one year is long-term.
    /// Day-counting is calendar days from openDate to closeDate inclusive.
    public static func classify(openDate: Date, closeDate: Date) -> HoldingPeriod {
        let cal = Calendar(identifier: .gregorian)
        let days = cal.dateComponents([.day], from: openDate, to: closeDate).day ?? 0
        return days > 365 ? .longTerm : .shortTerm
    }
}

// MARK: - Tax lot

/// A tax lot is a single acquisition tranche of a security. Per-share basis
/// may be adjusted upward by wash-sale or superficial-loss disallowance.
public struct TaxLot: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let symbol: Symbol
    public let openDate: Date
    public var quantity: Decimal
    public var costBasis: Decimal           // per-share, includes any disallowance adjustment
    public var washSaleAdjustment: Decimal  // running per-share adjustment, audit trail

    public init(
        id: UUID = UUID(),
        symbol: Symbol,
        openDate: Date,
        quantity: Decimal,
        costBasis: Decimal,
        washSaleAdjustment: Decimal = 0
    ) {
        self.id = id
        self.symbol = symbol
        self.openDate = openDate
        self.quantity = quantity
        self.costBasis = costBasis
        self.washSaleAdjustment = washSaleAdjustment
    }

    public var totalCost: Decimal { quantity * costBasis }
}

// MARK: - Disposition

/// A realized tax event from selling all or part of one or more lots.
/// One disposition is emitted per sell fill. If the sell consumes multiple
/// lots, each lot produces its own disposition so holding-period and
/// wash-sale treatment can differ between them.
public struct Disposition: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let symbol: Symbol
    public let openDate: Date
    public let closeDate: Date
    public let quantity: Decimal
    public let proceeds: Money              // gross of commission, in position currency
    public let costBasis: Money             // total basis consumed
    public let realizedPnL: Money           // proceeds - costBasis (pre-disallowance)
    public let holdingPeriod: HoldingPeriod
    public var washSaleDisallowed: Money?   // None = fully allowed; Some(amount) = loss disallowed

    public init(
        id: UUID = UUID(),
        symbol: Symbol,
        openDate: Date,
        closeDate: Date,
        quantity: Decimal,
        proceeds: Money,
        costBasis: Money,
        realizedPnL: Money,
        holdingPeriod: HoldingPeriod,
        washSaleDisallowed: Money? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.openDate = openDate
        self.closeDate = closeDate
        self.quantity = quantity
        self.proceeds = proceeds
        self.costBasis = costBasis
        self.realizedPnL = realizedPnL
        self.holdingPeriod = holdingPeriod
        self.washSaleDisallowed = washSaleDisallowed
    }

    /// The taxable amount after disallowance. A disallowed loss has its
    /// pnl effectively zeroed for tax purposes (the disallowed amount is
    /// transferred to a future replacement lot's basis).
    public var taxableRealizedPnL: Money {
        guard let disallowed = washSaleDisallowed else { return realizedPnL }
        return Money(realizedPnL.amount + disallowed.amount, realizedPnL.currency)
    }
}

// MARK: - Year summary

public struct TaxYearSummary: Sendable, Codable, Hashable {
    public let year: Int
    public let currency: Currency
    public let grossGain: Decimal
    public let grossLoss: Decimal
    public let netRealized: Decimal
    public let shortTermNet: Decimal
    public let longTermNet: Decimal
    public let washSaleDisallowed: Decimal

    public init(
        year: Int,
        currency: Currency,
        grossGain: Decimal,
        grossLoss: Decimal,
        netRealized: Decimal,
        shortTermNet: Decimal,
        longTermNet: Decimal,
        washSaleDisallowed: Decimal
    ) {
        self.year = year
        self.currency = currency
        self.grossGain = grossGain
        self.grossLoss = grossLoss
        self.netRealized = netRealized
        self.shortTermNet = shortTermNet
        self.longTermNet = longTermNet
        self.washSaleDisallowed = washSaleDisallowed
    }

    /// Aggregate a stream of dispositions into per-year, per-currency summaries.
    /// Disposition currency is taken from the realizedPnL field; cross-currency
    /// netting is the consumer's responsibility (deferred to multi-currency phase).
    public static func summarize(_ dispositions: [Disposition]) -> [TaxYearSummary] {
        let cal = Calendar(identifier: .gregorian)
        struct Bucket {
            var grossGain: Decimal = 0
            var grossLoss: Decimal = 0
            var shortNet: Decimal = 0
            var longNet: Decimal = 0
            var disallowed: Decimal = 0
        }
        var buckets: [String: (Int, Currency, Bucket)] = [:]
        for d in dispositions {
            let year = cal.component(.year, from: d.closeDate)
            let key = "\(year)-\(d.realizedPnL.currency.rawValue)"
            var entry = buckets[key] ?? (year, d.realizedPnL.currency, Bucket())
            let taxable = d.taxableRealizedPnL.amount
            if taxable >= 0 {
                entry.2.grossGain += taxable
            } else {
                entry.2.grossLoss += taxable  // negative
            }
            switch d.holdingPeriod {
            case .shortTerm: entry.2.shortNet += taxable
            case .longTerm:  entry.2.longNet  += taxable
            }
            if let dis = d.washSaleDisallowed {
                entry.2.disallowed += abs(dis.amount)
            }
            buckets[key] = entry
        }
        return buckets.values
            .map { (year, currency, b) in
                TaxYearSummary(
                    year: year,
                    currency: currency,
                    grossGain: b.grossGain,
                    grossLoss: b.grossLoss,
                    netRealized: b.grossGain + b.grossLoss,
                    shortTermNet: b.shortNet,
                    longTermNet: b.longNet,
                    washSaleDisallowed: b.disallowed
                )
            }
            .sorted { ($0.year, $0.currency.rawValue) < ($1.year, $1.currency.rawValue) }
    }
}

// MARK: - Regime protocol

/// A `TaxRegime` decides how lots are consumed on sell, how realized P&L is
/// computed, and how loss disallowance rules (wash-sale, superficial-loss)
/// are applied.
///
/// Implementations are pure and stateless — the engine owns lot and
/// disposition storage. This keeps regimes swappable mid-design and easy
/// to test in isolation.
public protocol TaxRegime: Sendable {
    /// Produce dispositions from a sell fill, mutating the lot list FIFO.
    /// Returns one disposition per consumed lot.
    func dispose(
        fill: Fill,
        lots: inout [TaxLot]
    ) -> [Disposition]

    /// Reconcile loss disallowance against subsequent purchases. Called once
    /// at end-of-backtest with the full disposition stream and the post-run
    /// lot history (a chronological record of every lot ever opened).
    /// Returns the adjusted dispositions and the adjusted final lots.
    func reconcileDisallowance(
        dispositions: [Disposition],
        lotHistory: [TaxLot]
    ) -> (dispositions: [Disposition], lots: [TaxLot])
}

// MARK: - NoTaxes default

/// Default regime: no lot tracking, no dispositions, no reconciliation.
/// Preserves v0.2 behavior exactly so existing backtests are unchanged.
public struct NoTaxes: TaxRegime {
    public init() {}

    public func dispose(fill: Fill, lots: inout [TaxLot]) -> [Disposition] {
        []
    }

    public func reconcileDisallowance(
        dispositions: [Disposition],
        lotHistory: [TaxLot]
    ) -> (dispositions: [Disposition], lots: [TaxLot]) {
        (dispositions, lotHistory)
    }
}
