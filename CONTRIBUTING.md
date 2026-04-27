# Contributing to Athena

Thanks for your interest. Athena is a Swift backtesting engine maintained by
Rives Cloud Solutions. This guide describes how to contribute productively.

## Ground rules

1. **Correctness over cleverness.** Numerical results must match a reference
   implementation (Python `pandas-ta`, `ta-lib`) within reasonable floating
   point tolerance. PRs adding indicators must include a test with a hand-
   computable or reference-pinned expected value.
2. **No new dependencies without discussion.** Open an issue first.
3. **Public API is sacred.** Breaking changes require a major version bump.
   Pre-1.0 we are more flexible, but document everything in `CHANGELOG.md`.
4. **All code is Apache-2.0.** By submitting a PR you agree your contribution
   is licensed under the project's license.

## Development workflow

```bash
# 1. Fork and clone
git clone https://github.com/<you>/Athena.git
cd Athena

# 2. Build
swift build

# 3. Run tests
swift test

# 4. Run the coverage gate (required before submitting a PR)
./scripts/coverage.sh

# 5. Run the example end-to-end (optional but recommended)
mkdir -p data
curl -L 'https://query1.finance.yahoo.com/v7/finance/download/SPY?period1=1577836800&period2=1735689600&interval=1d&events=history' \
  -o data/SPY.csv
swift run MACrossoverExample
```

## Pull request checklist

Before opening a PR:

- [ ] `swift build` is clean (no warnings introduced).
- [ ] `swift test` passes.
- [ ] `./scripts/coverage.sh` reports ≥ 90% line coverage on `Sources/`.
- [ ] New public types and functions have doc comments.
- [ ] `CHANGELOG.md` has an entry under `## [Unreleased]`.
- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).
- [ ] Branch name is `<type>/short-kebab-description`.

## Commit format

```
<type>[optional scope]: <description>
```

Valid types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`. Examples:

```
feat(indicators): add Bollinger Bands
fix(backtest): drawdown computation off-by-one on flat curves
docs: clarify indicator warmup semantics
```

## Reporting bugs

Open an issue with:

- Swift version (`swift --version`)
- macOS version
- Minimal reproducer (a small `main.swift` is best)
- Expected vs actual behavior

## Scope

v0.1 is intentionally narrow: incremental indicators, single-symbol or simple
multi-symbol backtests on daily bars, CSV input, simulated broker, simple
commission/slippage models. See the README for what's in vs out of scope.

If you're unsure whether a contribution fits, open an issue first.
