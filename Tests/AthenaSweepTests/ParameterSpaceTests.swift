import XCTest
@testable import AthenaSweep

final class ParameterSpaceTests: XCTestCase {

    // MARK: - grid

    func testGridCartesianProduct() {
        let axes: [ParameterAxis] = [
            .ints("fast", [5, 10]),
            .ints("slow", [50, 100, 200]),
        ]
        let space = ParameterSpace.grid(axes)
        XCTAssertEqual(space.sets.count, 6)
        // Every (fast, slow) combination present exactly once.
        var seen: Set<String> = []
        for s in space.sets {
            let key = "\(s.int("fast")!),\(s.int("slow")!)"
            XCTAssertFalse(seen.contains(key), "duplicate combo \(key)")
            seen.insert(key)
        }
        XCTAssertEqual(seen.count, 6)
    }

    func testGridSingleAxis() {
        let space = ParameterSpace.grid([.ints("p", [1, 2, 3])])
        XCTAssertEqual(space.sets.count, 3)
        XCTAssertEqual(space.sets.compactMap { $0.int("p") }.sorted(), [1, 2, 3])
    }

    func testGridEmptyAxesReturnsEmpty() {
        XCTAssertEqual(ParameterSpace.grid([]).sets.count, 0)
    }

    func testGridEmptyValuesReturnsEmpty() {
        let space = ParameterSpace.grid([.ints("p", []), .ints("q", [1])])
        XCTAssertEqual(space.sets.count, 0)
    }

    func testGridMixedTypes() {
        let space = ParameterSpace.grid([
            .ints("n", [1, 2]),
            .strings("mode", ["a", "b"]),
            .bools("flag", [true]),
        ])
        XCTAssertEqual(space.sets.count, 4)
        for s in space.sets {
            XCTAssertNotNil(s.int("n"))
            XCTAssertNotNil(s.string("mode"))
            XCTAssertEqual(s.bool("flag"), true)
        }
    }

    // MARK: - random

    func testRandomDeterministicWithSameSeed() {
        let axes: [ParameterAxis] = [
            .ints("a", [1, 2, 3, 4, 5]),
            .ints("b", [10, 20, 30, 40, 50]),
        ]
        let s1 = ParameterSpace.random(axes: axes, count: 20, seed: 42)
        let s2 = ParameterSpace.random(axes: axes, count: 20, seed: 42)
        XCTAssertEqual(s1.sets.count, 20)
        XCTAssertEqual(s2.sets.count, 20)
        for (a, b) in zip(s1.sets, s2.sets) {
            XCTAssertEqual(a.int("a"), b.int("a"))
            XCTAssertEqual(a.int("b"), b.int("b"))
        }
    }

    func testRandomDifferentSeedsDiffer() {
        let axes: [ParameterAxis] = [.ints("a", [1, 2, 3, 4, 5])]
        let s1 = ParameterSpace.random(axes: axes, count: 50, seed: 1)
        let s2 = ParameterSpace.random(axes: axes, count: 50, seed: 2)
        let v1 = s1.sets.map { $0.int("a")! }
        let v2 = s2.sets.map { $0.int("a")! }
        XCTAssertNotEqual(v1, v2)
    }

    func testRandomZeroCountReturnsEmpty() {
        let axes: [ParameterAxis] = [.ints("a", [1, 2, 3])]
        XCTAssertEqual(ParameterSpace.random(axes: axes, count: 0, seed: 1).sets.count, 0)
    }

    func testRandomEmptyAxesReturnsEmpty() {
        XCTAssertEqual(ParameterSpace.random(axes: [], count: 10, seed: 1).sets.count, 0)
    }

    func testRandomCoversAxisValues() {
        // With enough samples, each value should appear at least once.
        let axes: [ParameterAxis] = [.ints("a", [1, 2, 3])]
        let s = ParameterSpace.random(axes: axes, count: 100, seed: 7)
        let set = Set(s.sets.compactMap { $0.int("a") })
        XCTAssertEqual(set, [1, 2, 3])
    }

    // MARK: - typed accessors

    func testParameterSetTypedAccessors() {
        let p = ParameterSet([
            "i": AnySendableValue(42),
            "d": AnySendableValue(1.5),
            "dec": AnySendableValue(Decimal(string: "0.25")!),
            "s": AnySendableValue("hi"),
            "b": AnySendableValue(true),
        ])
        XCTAssertEqual(p.int("i"), 42)
        XCTAssertEqual(p.double("d"), 1.5)
        XCTAssertEqual(p.decimal("dec"), Decimal(string: "0.25"))
        XCTAssertEqual(p.string("s"), "hi")
        XCTAssertEqual(p.bool("b"), true)
        // Cross-type coercions
        XCTAssertEqual(p.double("i"), 42.0)
        XCTAssertEqual(p.decimal("i"), Decimal(42))
        XCTAssertNil(p.int("s"))
    }

    func testRNGAvoidsAllZeroState() {
        // SplitMix never produces all-zero from a finite seed; spot-check
        // by drawing a few values and ensuring they're nonzero.
        var rng = Xoshiro256StarStar(seed: 0)
        let v1 = rng.next()
        let v2 = rng.next()
        XCTAssertNotEqual(v1, 0)
        XCTAssertNotEqual(v2, 0)
        XCTAssertNotEqual(v1, v2)
    }
}
