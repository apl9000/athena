import Foundation
import AthenaCore

// MARK: - Commission

public protocol CommissionModel: Sendable {
    func commission(for order: Order, fillPrice: Decimal) -> Money
}

public struct FreeCommission: CommissionModel {
    public let currency: Currency
    public init(currency: Currency = .cad) { self.currency = currency }
    public func commission(for order: Order, fillPrice: Decimal) -> Money {
        Money(0, currency)
    }
}

public struct FixedCommission: CommissionModel {
    public let amount: Decimal
    public let currency: Currency
    public init(amount: Decimal, currency: Currency = .cad) {
        self.amount = amount
        self.currency = currency
    }
    public func commission(for order: Order, fillPrice: Decimal) -> Money {
        Money(amount, currency)
    }
}

/// Per-share commission with floor and percent cap — models IBKR Pro "tiered" pricing.
public struct PerShareCommission: CommissionModel {
    public let perShare: Decimal
    public let minimum: Decimal
    public let maxPercent: Decimal  // 0.01 = 1% of trade value cap
    public let currency: Currency

    public init(
        perShare: Decimal = 0.005,
        minimum: Decimal = 1.0,
        maxPercent: Decimal = 0.01,
        currency: Currency = .usd
    ) {
        self.perShare = perShare
        self.minimum = minimum
        self.maxPercent = maxPercent
        self.currency = currency
    }

    public func commission(for order: Order, fillPrice: Decimal) -> Money {
        let raw = order.quantity * perShare
        let cap = order.quantity * fillPrice * maxPercent
        return Money(min(max(raw, minimum), cap), currency)
    }
}

/// Questrade-style stocks: $0.01/share, min $4.95, max $9.95. ETF buys are free.
public struct QuestradeStockCommission: CommissionModel {
    public init() {}
    public func commission(for order: Order, fillPrice: Decimal) -> Money {
        let raw = order.quantity * Decimal(string: "0.01")!
        let clamped = min(max(raw, Decimal(string: "4.95")!), Decimal(string: "9.95")!)
        return Money(clamped, .cad)
    }
}

// MARK: - Slippage

public protocol SlippageModel: Sendable {
    func fillPrice(referencePrice: Decimal, order: Order, bar: Bar) -> Decimal
}

public struct NoSlippage: SlippageModel {
    public init() {}
    public func fillPrice(referencePrice: Decimal, order: Order, bar: Bar) -> Decimal {
        referencePrice
    }
}

/// Fixed basis-points slippage — the conservative default. 2 bps is ~typical
/// for liquid US equities. Bump to 5–10 for small-caps, 20+ for illiquid.
public struct FixedBpsSlippage: SlippageModel {
    public let bps: Decimal
    public init(bps: Decimal = 2) { self.bps = bps }

    public func fillPrice(referencePrice: Decimal, order: Order, bar: Bar) -> Decimal {
        let adj = referencePrice * (bps / 10_000)
        return order.side == .buy ? referencePrice + adj : referencePrice - adj
    }
}

/// Volume-impact model: slippage grows with sqrt(order_size / bar_volume).
/// Use this when backtesting larger sizes. The sqrt law is a crude but standard
/// approximation from market microstructure literature (Almgren et al.).
public struct VolumeImpactSlippage: SlippageModel {
    public let baseBps: Decimal
    public let impactFactor: Decimal

    public init(baseBps: Decimal = 2, impactFactor: Decimal = 50) {
        self.baseBps = baseBps
        self.impactFactor = impactFactor
    }

    public func fillPrice(referencePrice: Decimal, order: Order, bar: Bar) -> Decimal {
        let volumeRatio = order.quantity / max(Decimal(bar.volume), 1)
        let sqrtImpact = Self.decimalSqrt(volumeRatio) * impactFactor
        let totalBps = baseBps + sqrtImpact
        let adj = referencePrice * (totalBps / 10_000)
        return order.side == .buy ? referencePrice + adj : referencePrice - adj
    }

    private static func decimalSqrt(_ value: Decimal) -> Decimal {
        guard value > 0 else { return 0 }
        let d = NSDecimalNumber(decimal: value).doubleValue
        return Decimal(Foundation.sqrt(d))
    }
}

// MARK: - SimulatedBroker

/// A broker implementation for backtest and paper trading.
///
/// Fill semantics:
///   - Orders submitted during bar N fill at bar N+1's open (with slippage).
///   - This avoids look-ahead bias. Some backtesters fill at bar N's close,
///     which is technically a look-ahead if the strategy decided based on close.
///   - Limit orders fill if the bar trades through the limit price.
///   - Stop / stopLimit orders are stubbed in v0.1 — extend as needed.
public actor SimulatedBroker: Broker {
    private let portfolio: Portfolio
    private let commissionModel: CommissionModel
    private let slippageModel: SlippageModel
    private var pendingOrders: [Order] = []

    public init(
        portfolio: Portfolio,
        commissionModel: CommissionModel = FreeCommission(),
        slippageModel: SlippageModel = FixedBpsSlippage(bps: 2)
    ) {
        self.portfolio = portfolio
        self.commissionModel = commissionModel
        self.slippageModel = slippageModel
    }

    public func submit(_ order: Order) async throws -> Order {
        pendingOrders.append(order)
        return order
    }

    public func cancel(_ orderId: UUID) async throws {
        pendingOrders.removeAll { $0.id == orderId }
    }

    public func openOrders() async throws -> [Order] { pendingOrders }

    /// Called by the engine at the start of each bar — BEFORE the strategy runs.
    /// This is where pending orders fill.
    @discardableResult
    public func processBarOpen(_ bar: Bar) async -> [Fill] {
        var fills: [Fill] = []
        var keep: [Order] = []

        for order in pendingOrders where order.symbol == bar.symbol {
            if let fill = await tryFill(order: order, bar: bar) {
                fills.append(fill)
            } else if order.tif == .gtc {
                keep.append(order)
            }
            // day orders that don't fill are implicitly cancelled at bar end
        }

        // Preserve orders for other symbols (they may fill when their bar arrives)
        pendingOrders = pendingOrders.filter { $0.symbol != bar.symbol } + keep
        return fills
    }

    private func tryFill(order: Order, bar: Bar) async -> Fill? {
        switch order.type {
        case .market:
            let fillPrice = slippageModel.fillPrice(
                referencePrice: bar.open, order: order, bar: bar
            )
            return await makeFill(order: order, fillPrice: fillPrice, bar: bar,
                                  referenceForSlippage: bar.open)

        case .limit(let limitPrice):
            let eligible = order.side == .buy
                ? bar.low <= limitPrice
                : bar.high >= limitPrice
            guard eligible else { return nil }
            // Pessimistic assumption: we get exactly the limit price, not better.
            return await makeFill(order: order, fillPrice: limitPrice, bar: bar,
                                  referenceForSlippage: limitPrice)

        case .stop, .stopLimit:
            // TODO: stop-order semantics in v0.2
            return nil
        }
    }

    private func makeFill(
        order: Order, fillPrice: Decimal, bar: Bar, referenceForSlippage: Decimal
    ) async -> Fill {
        let commission = commissionModel.commission(for: order, fillPrice: fillPrice)
        let slippageBps = referenceForSlippage > 0
            ? ((fillPrice - referenceForSlippage) / referenceForSlippage) * 10_000
            : 0
        let fill = Fill(
            orderId: order.id,
            symbol: order.symbol,
            side: order.side,
            quantity: order.quantity,
            price: fillPrice,
            commission: commission,
            slippageBps: slippageBps,
            filledAt: bar.timestamp
        )
        await portfolio.apply(fill)
        return fill
    }
}
