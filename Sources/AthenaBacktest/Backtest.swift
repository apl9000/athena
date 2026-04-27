import Foundation
import AthenaCore
import AthenaIndicators
import AthenaBrokers

// MARK: - Config

public struct BacktestConfig: Sendable {
    public let startDate: Date
    public let endDate: Date
    public let initialCash: Money
    public let commission: any CommissionModel
    public let slippage: any SlippageModel

    public init(
        startDate: Date,
        endDate: Date,
        initialCash: Money,
        commission: any CommissionModel = FreeCommission(),
        slippage: any SlippageModel = FixedBpsSlippage(bps: 2)
    ) {
        self.startDate = startDate
        self.endDate = endDate
        self.initialCash = initialCash
        self.commission = commission
        self.slippage = slippage
    }
}

// MARK: - Result

public struct BacktestResult: Sendable {
    public let initialEquity: Money
    public let finalEquity: Money
    public let snapshots: [PortfolioSnapshot]
    public let fills: [Fill]

    public var totalReturn: Decimal {
        guard initialEquity.amount > 0 else { return 0 }
        return (finalEquity.amount - initialEquity.amount) / initialEquity.amount
    }

    /// Peak-to-trough drawdown as a positive fraction (0.25 = 25% drawdown).
    public var maxDrawdown: Decimal {
        var peak: Decimal = 0
        var maxDD: Decimal = 0
        for snap in snapshots {
            peak = Swift.max(peak, snap.totalValue.amount)
            guard peak > 0 else { continue }
            let dd = (peak - snap.totalValue.amount) / peak
            maxDD = Swift.max(maxDD, dd)
        }
        return maxDD
    }

    /// Annualized Sharpe with 0% risk-free rate. Assumes daily bars.
    /// For other frequencies, scale by sqrt(periods_per_year) manually.
    public var sharpe: Double {
        guard snapshots.count > 1 else { return 0 }
        let values = snapshots.map { NSDecimalNumber(decimal: $0.totalValue.amount).doubleValue }
        var returns: [Double] = []
        returns.reserveCapacity(values.count - 1)
        for i in 1..<values.count {
            guard values[i - 1] > 0 else { continue }
            returns.append((values[i] - values[i - 1]) / values[i - 1])
        }
        guard !returns.isEmpty else { return 0 }
        let mean = returns.reduce(0, +) / Double(returns.count)
        let variance = returns.map { pow($0 - mean, 2) }.reduce(0, +) / Double(returns.count)
        let stdev = Foundation.sqrt(variance)
        guard stdev > 0 else { return 0 }
        return (mean / stdev) * Foundation.sqrt(252)
    }
}

// MARK: - Engine

/// Event-driven backtest engine.
///
/// Loop per bar:
///   1. Advance the clock to the bar's timestamp
///   2. Pending orders fill at this bar's open (with slippage + commission)
///   3. Indicators update with this bar's close
///   4. Strategy reacts (submits new orders for the next bar)
///   5. Portfolio snapshots with mark-to-market at close
///
/// This ordering ensures:
///   - No look-ahead bias: strategy sees the close but can only act on the next bar
///   - ACB is maintained correctly on every fill
///   - Equity curve is consistent (snapshot at close, after all fills for the bar)
public actor BacktestEngine {
    private let config: BacktestConfig
    private let strategy: any Strategy
    private let bars: [Bar]

    public init(config: BacktestConfig, strategy: any Strategy, bars: [Bar]) {
        self.config = config
        self.strategy = strategy
        self.bars = bars.sorted { $0.timestamp < $1.timestamp }
    }

    public func run() async throws -> BacktestResult {
        let portfolio = Portfolio(
            baseCurrency: config.initialCash.currency,
            initialCash: config.initialCash
        )
        let broker = SimulatedBroker(
            portfolio: portfolio,
            commissionModel: config.commission,
            slippageModel: config.slippage
        )
        let clock = BacktestClock(start: config.startDate)
        let indicators = IndicatorCache()

        let ctx = StrategyContext(
            portfolio: portfolio,
            broker: broker,
            clock: clock,
            indicators: indicators
        )

        try await strategy.onStart(context: ctx)

        var marks: [Symbol: Decimal] = [:]

        for bar in bars where bar.timestamp >= config.startDate && bar.timestamp <= config.endDate {
            await clock.advance(to: bar.timestamp)

            // Fills (orders from previous bar)
            _ = await broker.processBarOpen(bar)

            // Update indicators with this bar's close
            await indicators.update(with: bar)

            // Strategy reacts
            try await strategy.onBar(bar, context: ctx)

            // Mark-to-market snapshot at close
            marks[bar.symbol] = bar.close
            await portfolio.snapshot(at: bar.timestamp, marks: marks)
        }

        try await strategy.onFinish(context: ctx)

        let finalEquity = await portfolio.equity(marks: marks)
        let snapshots = await portfolio.history
        let allFills = await portfolio.fills

        return BacktestResult(
            initialEquity: config.initialCash,
            finalEquity: finalEquity,
            snapshots: snapshots,
            fills: allFills
        )
    }
}
