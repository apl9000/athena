import Foundation

// MARK: - Broker

public protocol Broker: Sendable {
    func submit(_ order: Order) async throws -> Order
    func cancel(_ orderId: UUID) async throws
    func openOrders() async throws -> [Order]
}

public enum BrokerError: Error, Sendable {
    case insufficientCash
    case unknownSymbol(Symbol)
    case orderNotFound(UUID)
    case rejected(reason: String)
}

// MARK: - Strategy

public protocol Strategy: Sendable {
    /// Called once before the first bar. Register indicators, set state.
    func onStart(context: StrategyContext) async throws

    /// Called on every new bar. Query indicators, inspect portfolio, submit orders.
    func onBar(_ bar: Bar, context: StrategyContext) async throws

    /// Called once after the last bar. Close positions if needed, emit summaries.
    func onFinish(context: StrategyContext) async throws
}

public extension Strategy {
    func onStart(context: StrategyContext) async throws {}
    func onFinish(context: StrategyContext) async throws {}
}

// MARK: - StrategyContext

/// The context is intentionally small. It's the API surface strategies depend on —
/// keep it stable. If you're tempted to add something here, ask whether the strategy
/// really needs it or whether it belongs somewhere else.
public struct StrategyContext: Sendable {
    public let portfolio: Portfolio
    public let broker: any Broker
    public let clock: any Clock
    public let indicators: any IndicatorProvider

    public init(
        portfolio: Portfolio,
        broker: any Broker,
        clock: any Clock,
        indicators: any IndicatorProvider
    ) {
        self.portfolio = portfolio
        self.broker = broker
        self.clock = clock
        self.indicators = indicators
    }

    @discardableResult
    public func buy(
        _ symbol: Symbol,
        quantity: Decimal,
        type: OrderType = .market,
        tif: TimeInForce = .day
    ) async throws -> Order {
        let order = Order(
            symbol: symbol, side: .buy, quantity: quantity,
            type: type, tif: tif, createdAt: await clock.now
        )
        return try await broker.submit(order)
    }

    @discardableResult
    public func sell(
        _ symbol: Symbol,
        quantity: Decimal,
        type: OrderType = .market,
        tif: TimeInForce = .day
    ) async throws -> Order {
        let order = Order(
            symbol: symbol, side: .sell, quantity: quantity,
            type: type, tif: tif, createdAt: await clock.now
        )
        return try await broker.submit(order)
    }
}
