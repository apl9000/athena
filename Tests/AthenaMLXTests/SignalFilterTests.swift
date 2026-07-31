import XCTest
@testable import AthenaMLX

final class DebounceFilterTests: XCTestCase {

    // MARK: Conformance

    func test_debounceFilter_conformsToSignalFilter() {
        let filter: any SignalFilter = DebounceFilter(minBars: 2)
        XCTAssertTrue(filter is DebounceFilter)
    }

    // MARK: Empty input

    func test_debounceFilter_emptyInput_returnsEmptyOutput() {
        let filter = DebounceFilter(minBars: 2)
        let result = filter.filter([])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: Length invariant

    func test_debounceFilter_preservesSignalCount() {
        let filter = DebounceFilter(minBars: 3)
        let signals = [true, false, true, false, true, false]
        let result = filter.filter(signals)
        XCTAssertEqual(result.count, signals.count)
    }

    // MARK: Debounce behaviour

    func test_debounceFilter_suppressesFlipWithinWindow() {
        // flip at i=1, then flip-back at i=2 — within 3-bar window, suppress i=2
        let filter = DebounceFilter(minBars: 3)
        let signals = [false, true, false, false, false]
        let result = filter.filter(signals)
        XCTAssertEqual(result, [false, true, true, true, false],
                       "Flips at i=2 and i=3 must both be suppressed — within 3-bar debounce window")
    }

    func test_debounceFilter_allowsFlipAfterWindow() {
        // flip at i=1, next at i=4 — gap of 3 meets the minBars=3 threshold
        let filter = DebounceFilter(minBars: 3)
        let signals = [false, true, true, true, false]
        let result = filter.filter(signals)
        XCTAssertEqual(result[4], false,
                       "Flip at i=4 must pass through — gap of 3 meets the minBars threshold")
    }
}
