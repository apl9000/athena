import Foundation

// MARK: - Corporate actions

/// A corporate action that affects the holder of a security on its ex-date.
///
/// Athena uses *position adjustment* (not historical-price adjustment): bars stay
/// raw — the open/high/low/close are exactly what was published on the day —
/// and the holder's position quantity, cost basis, and cash are updated when
/// the action fires. This matches what a live trading account experiences.
///
/// Strategies that prefer pre-adjusted prices can simply omit a
/// `CorporateActionSource` from the engine and use adjusted-close data.
public enum CorporateAction: Sendable, Hashable {
    /// Stock split. `ratio` is the new-shares-for-one ratio:
    ///   - 4-for-1 split → ratio = 4 (each share becomes 4)
    ///   - 3-for-2 split → ratio = 1.5
    ///   - 1-for-10 reverse split → ratio = 0.1
    case split(ratio: Decimal)

    /// Ordinary cash dividend. `perShare` is paid in the position's currency.
    case cashDividend(perShare: Money)
}

public struct CorporateActionEvent: Sendable, Hashable {
    public let symbol: Symbol
    /// Effective date — the date on which the action applies to holders.
    /// In Athena this is treated as the ex-date.
    public let exDate: Date
    public let action: CorporateAction

    public init(symbol: Symbol, exDate: Date, action: CorporateAction) {
        self.symbol = symbol
        self.exDate = exDate
        self.action = action
    }
}

/// Source of corporate actions for a symbol on a given date.
/// Implementations are typically backed by static CSVs, vendor APIs,
/// or — in tests — fixed in-memory tables.
public protocol CorporateActionSource: Sendable {
    func actions(for symbol: Symbol, on date: Date) async -> [CorporateActionEvent]
}

/// No-op source — equivalent to no corporate-action handling. Default for engines
/// that don't supply one.
public struct NoCorporateActions: CorporateActionSource {
    public init() {}
    public func actions(for symbol: Symbol, on date: Date) async -> [CorporateActionEvent] {
        []
    }
}
