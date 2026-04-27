.PHONY: build test coverage example clean

build:
	swift build

test:
	swift test

coverage:
	./scripts/coverage.sh

example:
	swift run MACrossoverExample

clean:
	swift package clean
	rm -rf .build coverage.lcov
