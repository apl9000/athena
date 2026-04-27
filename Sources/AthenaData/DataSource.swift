import Foundation
import AthenaCore

public protocol DataSource: Sendable {
    func bars(for symbol: Symbol, from: Date, to: Date) async throws -> [Bar]
}

public enum DataSourceError: Error, Sendable {
    case fileNotFound(URL)
    case malformedRow(Int)
    case unsupportedFormat(String)
}

/// Reads bars from a CSV with header `Date,Open,High,Low,Close,Volume`
/// (the standard Yahoo Finance export format). Timestamps are parsed in
/// the supplied time zone (default: America/New_York, US market close).
public struct CSVDataSource: DataSource {
    public let path: URL
    public let symbol: Symbol
    public let dateFormat: String
    public let timeZone: TimeZone

    public init(
        path: URL,
        symbol: Symbol,
        dateFormat: String = "yyyy-MM-dd",
        timeZone: TimeZone = TimeZone(identifier: "America/New_York")!
    ) {
        self.path = path
        self.symbol = symbol
        self.dateFormat = dateFormat
        self.timeZone = timeZone
    }

    public func bars(for symbol: Symbol, from: Date, to: Date) async throws -> [Bar] {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw DataSourceError.fileNotFound(path)
        }
        let text = try String(contentsOf: path, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > 1 else { return [] }

        let formatter = DateFormatter()
        formatter.dateFormat = dateFormat
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var bars: [Bar] = []
        bars.reserveCapacity(lines.count)

        for (i, line) in lines.dropFirst().enumerated() {
            let fields = line.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard fields.count >= 6 else {
                throw DataSourceError.malformedRow(i + 2)  // +2 for header + 1-indexed
            }
            guard
                let date = formatter.date(from: fields[0]),
                let open = Decimal(string: fields[1]),
                let high = Decimal(string: fields[2]),
                let low = Decimal(string: fields[3]),
                let close = Decimal(string: fields[4]),
                let volume = Int(fields[5])
            else {
                throw DataSourceError.malformedRow(i + 2)
            }
            guard date >= from, date <= to else { continue }
            bars.append(Bar(
                symbol: symbol, timestamp: date,
                open: open, high: high, low: low, close: close,
                volume: volume
            ))
        }
        return bars.sorted { $0.timestamp < $1.timestamp }
    }
}
