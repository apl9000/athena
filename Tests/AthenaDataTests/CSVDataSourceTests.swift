import XCTest
import AthenaCore
@testable import AthenaData

final class CSVDataSourceTests: XCTestCase {

    private func writeTempCSV(_ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("athena-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.csv")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testHappyPath() async throws {
        let csv = """
        Date,Open,High,Low,Close,Volume
        2024-01-02,100.00,101.00,99.50,100.50,1000000
        2024-01-03,100.50,102.00,100.00,101.50,1100000
        2024-01-04,101.50,103.00,101.00,102.50,1200000
        """
        let url = try writeTempCSV(csv)
        let source = CSVDataSource(path: url, symbol: Symbol("SPY"))
        let bars = try await source.bars(for: Symbol("SPY"),
                                         from: Date(timeIntervalSince1970: 0),
                                         to: Date(timeIntervalSince1970: 9_999_999_999))
        XCTAssertEqual(bars.count, 3)
        XCTAssertEqual(bars[0].open, Decimal(string: "100.00"))
        XCTAssertEqual(bars[2].close, Decimal(string: "102.50"))
        XCTAssertEqual(bars[0].volume, 1_000_000)
        XCTAssertEqual(bars[0].symbol, Symbol("SPY"))
    }

    func testFileNotFound() async {
        let url = URL(fileURLWithPath: "/tmp/nope-\(UUID().uuidString).csv")
        let source = CSVDataSource(path: url, symbol: Symbol("X"))
        do {
            _ = try await source.bars(for: Symbol("X"),
                                       from: Date(timeIntervalSince1970: 0),
                                       to: Date(timeIntervalSince1970: 9_999_999_999))
            XCTFail("Expected fileNotFound")
        } catch DataSourceError.fileNotFound {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testMalformedRowTooFewFields() async throws {
        let url = try writeTempCSV("""
        Date,Open,High,Low,Close,Volume
        2024-01-02,100,101,99
        """)
        let source = CSVDataSource(path: url, symbol: Symbol("X"))
        do {
            _ = try await source.bars(for: Symbol("X"),
                                       from: Date(timeIntervalSince1970: 0),
                                       to: Date(timeIntervalSince1970: 9_999_999_999))
            XCTFail("Expected malformedRow")
        } catch DataSourceError.malformedRow(let row) {
            XCTAssertEqual(row, 2)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testMalformedRowBadDate() async throws {
        let url = try writeTempCSV("""
        Date,Open,High,Low,Close,Volume
        not-a-date,100,101,99,100,1000
        """)
        let source = CSVDataSource(path: url, symbol: Symbol("X"))
        do {
            _ = try await source.bars(for: Symbol("X"),
                                       from: Date(timeIntervalSince1970: 0),
                                       to: Date(timeIntervalSince1970: 9_999_999_999))
            XCTFail("Expected malformedRow")
        } catch DataSourceError.malformedRow {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testMalformedRowBadNumber() async throws {
        let url = try writeTempCSV("""
        Date,Open,High,Low,Close,Volume
        2024-01-02,abc,101,99,100,1000
        """)
        let source = CSVDataSource(path: url, symbol: Symbol("X"))
        do {
            _ = try await source.bars(for: Symbol("X"),
                                       from: Date(timeIntervalSince1970: 0),
                                       to: Date(timeIntervalSince1970: 9_999_999_999))
            XCTFail("Expected malformedRow")
        } catch DataSourceError.malformedRow {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testEmptyCSVReturnsEmpty() async throws {
        let url = try writeTempCSV("Date,Open,High,Low,Close,Volume\n")
        let source = CSVDataSource(path: url, symbol: Symbol("X"))
        let bars = try await source.bars(for: Symbol("X"),
                                          from: Date(timeIntervalSince1970: 0),
                                          to: Date(timeIntervalSince1970: 9_999_999_999))
        XCTAssertEqual(bars.count, 0)
    }

    func testDateRangeFiltering() async throws {
        let url = try writeTempCSV("""
        Date,Open,High,Low,Close,Volume
        2024-01-02,100,101,99,100,1000
        2024-02-02,110,111,109,110,1000
        2024-03-02,120,121,119,120,1000
        """)
        let source = CSVDataSource(path: url, symbol: Symbol("X"))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let from = formatter.date(from: "2024-01-15")!
        let to = formatter.date(from: "2024-02-15")!
        let bars = try await source.bars(for: Symbol("X"), from: from, to: to)
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars[0].close, 110)
    }

    func testSortOrderAscending() async throws {
        let url = try writeTempCSV("""
        Date,Open,High,Low,Close,Volume
        2024-03-02,120,121,119,120,1000
        2024-01-02,100,101,99,100,1000
        2024-02-02,110,111,109,110,1000
        """)
        let source = CSVDataSource(path: url, symbol: Symbol("X"))
        let bars = try await source.bars(for: Symbol("X"),
                                          from: Date(timeIntervalSince1970: 0),
                                          to: Date(timeIntervalSince1970: 9_999_999_999))
        XCTAssertEqual(bars.count, 3)
        XCTAssertLessThan(bars[0].timestamp, bars[1].timestamp)
        XCTAssertLessThan(bars[1].timestamp, bars[2].timestamp)
    }
}
