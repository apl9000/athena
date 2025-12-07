# 👩‍🔬 Athena (WORK IN PROGRESS)

Athena is a small math toolkit for statistics, geometry, and linear algebra.

## Install

```bash
deno add jsr:@apl/athena
```

## Usage

```ts
import { geometry, linearAlgebra, statistics } from "jsr:@apl/athena";

const avg = statistics.mean([1, 2, 3]);
const circle = geometry.circle({ radius: 2 });
const distance = linearAlgebra.distance([0, 0], [3, 4]);
```

Or import subpaths for smaller bundles:

```ts
import { mean } from "jsr:@apl/athena/statistics";
import { circleArea } from "jsr:@apl/athena/geometry";
```

## API highlights

- `statistics`: `mean`, `median`, `variance`, `standardDeviation`,
  `correlation`, `mode`, `range`
- `geometry`: `circle`, `square`, `rectangle` helpers with derived properties
- `linear_algebra`: `vectorAddition`, `dotProduct`, `distance`, `matrix`,
  `identityMatrix`

## Tasks

```bash
deno task fmt       # format
deno task lint      # lint
deno task test      # run tests
deno task coverage  # generate coverage.lcov
```

## Development

- Tests look for `*_test.ts`.
- CI (GitHub Actions) runs fmt, lint, and test on push/PR.
