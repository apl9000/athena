import Foundation

// MARK: - Symbol

public struct Symbol: Hashable, Sendable, CustomStringConvertible, Codable {
    public let ticker: String
    public let exchange: String?

    public init(_ ticker: String, exchange: String? = nil) {
        self.ticker = ticker.uppercased()
        self.exchange = exchange
    }

    public var description: String {
        if let exchange { return "\(ticker).\(exchange)" }
        return ticker
    }
}

// MARK: - Currency & Money

public enum Currency: String, Sendable, Codable, Hashable {
    case cad = "CAD"
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
}

/// A value in a specific currency. Uses Decimal to avoid FP drift on cash.
public struct Money: Sendable, Codable, Hashable {
    public let amount: Decimal
    public let currency: Currency

    public init(_ amount: Decimal, _ currency: Currency) {
        self.amount = amount
        self.currency = currency
    }

    public static func cad(_ amount: Decimal) -> Money { Money(amount, .cad) }
    public static func usd(_ amount: Decimal) -> Money { Money(amount, .usd) }

    public static func + (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cross-currency math must go through FX")
        return Money(lhs.amount + rhs.amount, lhs.currency)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cross-currency math must go through FX")
        return Money(lhs.amount - rhs.amount, lhs.currency)
    }

    public static func * (lhs: Money, rhs: Decimal) -> Money {
        Money(lhs.amount * rhs, lhs.currency)
    }
}

// MARK: - Side

public enum Side: String, Sendable, Codable {
    case buy, sell

    public var sign: Decimal { self == .buy ? 1 : -1 }
}

// MARK: - Bar

public struct Bar: Sendable, Codable, Hashable {
    public let symbol: Symbol
    public let timestamp: Date
    public let open: Decimal
    public let high: Decimal
    public let low: Decimal
    public let close: Decimal
    public let volume: Int
    /// Nil if the bar is already split/dividend adjusted.
    public let adjustmentFactor: Decimal?

    public init(
        symbol: Symbol,
        timestamp: Date,
        open: Decimal, high: Decimal, low: Decimal, close: Decimal,
        volume: Int,
        adjustmentFactor: Decimal? = nil
    ) {
        self.symbol = symbol
        self.timestamp = timestamp
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.adjustmentFactor = adjustmentFactor
    }
}

// MARK: - Order

public enum OrderType: Sendable, Codable, Hashable {
    case market
    case limit(Decimal)
    case stop(Decimal)
    case stopLimit(stop: Decimal, limit: Decimal)
}

public enum TimeInForce: String, Sendable, Codable {
    case day, gtc, ioc, fok
}

public enum OrderStatus: String, Sendable, Codable {
    case pending, filled, partial, cancelled, rejected, expired
}

public struct Order: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let symbol: Symbol
    public let side: Side
    public let quantity: Decimal   // fractional shares supported
    public let type: OrderType
    public let tif: TimeInForce
    public let createdAt: Date
    public var status: OrderStatus

    public init(
        id: UUID = UUID(),
        symbol: Symbol,
        side: Side,
        quantity: Decimal,
        type: OrderType = .market,
        tif: TimeInForce = .day,
        createdAt: Date,
        status: OrderStatus = .pending
    ) {
        self.id = id
        self.symbol = symbol
        self.side = side
        self.quantity = quantity
        self.type = type
        self.tif = tif
        self.createdAt = createdAt
        self.status = status
    }
}

public struct Fill: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let orderId: UUID
    public let symbol: Symbol
    public let side: Side
    public let quantity: Decimal
    public let price: Decimal
    public let commission: Money
    public let slippageBps: Decimal
    public let filledAt: Date

    public init(
        id: UUID = UUID(),
        orderId: UUID,
        symbol: Symbol,
        side: Side,
        quantity: Decimal,
        price: Decimal,
        commission: Money,
        slippageBps: Decimal,
        filledAt: Date
    ) {
        self.id = id
        self.orderId = orderId
        self.symbol = symbol
        self.side = side
        self.quantity = quantity
        self.price = price
        self.commission = commission
        self.slippageBps = slippageBps
        self.filledAt = filledAt
    }

    public var notional: Decimal { quantity * price }
}

// MARK: - Position

public struct Position: Sendable, Codable {
    public let symbol: Symbol
    public let currency: Currency
    public var quantity: Decimal
    public var avgCost: Decimal   // per share, ACB — Canadian tax lot treatment
    public var fills: [Fill]

    public init(symbol: Symbol, currency: Currency) {
        self.symbol = symbol
        self.currency = currency
        self.quantity = 0
        self.avgCost = 0
        self.fills = []
    }

    public var isOpen: Bool { quantity != 0 }

    public func marketValue(at price: Decimal) -> Money {
        Money(quantity * price, currency)
    }

    public func unrealizedPnL(at price: Decimal) -> Money {
        Money((price - avgCost) * quantity, currency)
    }
}

// MARK: - Portfolio

public struct PortfolioSnapshot: Sendable, Codable {
    public let timestamp: Date
    public let totalValue: Money
    public let cash: [Currency: Decimal]
    public let positions: [Symbol: Decimal]  // quantity by symbol

    public init(
        timestamp: Date,
        totalValue: Money,
        cash: [Currency: Decimal],
        positions: [Symbol: Decimal]
    ) {
        self.timestamp = timestamp
        self.totalValue = totalValue
        self.cash = cash
        self.positions = positions
    }
}

/// Portfolio is an actor — all mutation goes through it, making it safe to share
/// across the broker, strategy, and engine running on different tasks.
public actor Portfolio {
    public let baseCurrency: Currency
    public private(set) var cash: [Currency: Decimal]
    public private(set) var positions: [Symbol: Position]
    public private(set) var fills: [Fill]
    public private(set) var history: [PortfolioSnapshot]

    public init(baseCurrency: Currency = .cad, initialCash: Money) {
        precondition(
            initialCash.currency == baseCurrency,
            "Initial cash must match base currency. Multi-currency funding is a Phase 2 feature."
        )
        self.baseCurrency = baseCurrency
        self.cash = [baseCurrency: initialCash.amount]
        self.positions = [:]
        self.fills = []
        self.history = []
    }

    public func position(for symbol: Symbol) -> Position? {
        positions[symbol]
    }

    public func cashBalance(in currency: Currency) -> Money {
        Money(cash[currency] ?? 0, currency)
    }

    /// Apply a fill: update cash, position quantity, and cost basis (ACB).
    public func apply(_ fill: Fill) {
        let positionCurrency = positions[fill.symbol]?.currency ?? fill.commission.currency
        let notional = fill.quantity * fill.price

        // Cash leg
        let cashDelta = fill.side == .buy ? -notional : notional
        cash[positionCurrency, default: 0] += cashDelta
        cash[fill.commission.currency, default: 0] -= fill.commission.amount

        // Position leg — ACB weighted average on buys, no cost change on sells
        var pos = positions[fill.symbol] ?? Position(symbol: fill.symbol, currency: positionCurrency)
        if fill.side == .buy {
            let newQty = pos.quantity + fill.quantity
            if newQty > 0 {
                pos.avgCost = ((pos.quantity * pos.avgCost) + (fill.quantity * fill.price)) / newQty
            }
            pos.quantity = newQty
        } else {
            pos.quantity -= fill.quantity
            if pos.quantity == 0 { pos.avgCost = 0 }
        }
        pos.fills.append(fill)
        positions[fill.symbol] = pos
        fills.append(fill)
    }

    /// Apply a stock split to the held position. Total cost basis is preserved:
    /// shares are multiplied by `ratio`, per-share ACB is divided by `ratio`.
    /// No-op if the position is missing or zero. Cash is unaffected.
    public func applySplit(symbol: Symbol, ratio: Decimal) {
        precondition(ratio > 0, "Split ratio must be positive")
        guard var pos = positions[symbol], pos.quantity != 0 else { return }
        pos.quantity = pos.quantity * ratio
        pos.avgCost = pos.avgCost / ratio
        positions[symbol] = pos
    }

    /// Apply an ordinary cash dividend. Credits cash in the dividend's currency
    /// at `perShare * quantity_held`. ACB is unchanged — ordinary dividends are
    /// taxable income, not a return of capital. No-op if the position is missing
    /// or zero on the ex-date.
    public func applyCashDividend(symbol: Symbol, perShare: Money) {
        guard let pos = positions[symbol], pos.quantity > 0 else { return }
        let credit = perShare.amount * pos.quantity
        cash[perShare.currency, default: 0] += credit
    }

    /// Snapshot equity at a timestamp given the current marks.
    @discardableResult
    public func snapshot(at timestamp: Date, marks: [Symbol: Decimal]) -> PortfolioSnapshot {
        var total = cash[baseCurrency] ?? 0
        for (symbol, pos) in positions {
            guard let mark = marks[symbol] else { continue }
            // v0.1 is single-currency. Multi-currency equity goes through an FX provider later.
            guard pos.currency == baseCurrency else { continue }
            total += pos.quantity * mark
        }
        let snap = PortfolioSnapshot(
            timestamp: timestamp,
            totalValue: Money(total, baseCurrency),
            cash: cash,
            positions: positions.mapValues { $0.quantity }
        )
        history.append(snap)
        return snap
    }

    public func equity(marks: [Symbol: Decimal]) -> Money {
        var total = cash[baseCurrency] ?? 0
        for (symbol, pos) in positions {
            guard let mark = marks[symbol], pos.currency == baseCurrency else { continue }
            total += pos.quantity * mark
        }
        return Money(total, baseCurrency)
    }
}

// MARK: - Clock

/// Unified time source so the same Strategy runs identically in backtest, paper, and live.
/// In backtest the engine drives the clock; in live the clock is the wall clock.
public protocol Clock: Sendable {
    var now: Date { get async }
    func sleep(until date: Date) async throws
}

public actor BacktestClock: Clock {
    public private(set) var current: Date

    public init(start: Date) { self.current = start }

    public var now: Date { current }

    public func advance(to date: Date) {
        precondition(date >= current, "Backtest clock cannot move backwards")
        self.current = date
    }

    public func sleep(until date: Date) async throws {
        // In backtest, sleep is instantaneous — the engine controls time.
    }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(until date: Date) async throws {
        let interval = date.timeIntervalSinceNow
        if interval > 0 { try await Task.sleep(for: .seconds(interval)) }
    }
}
