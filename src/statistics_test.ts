import { assertEquals } from "@std/assert";
import { assertAlmostEquals } from "@std/assert";
import {
  correlation,
  mean,
  median,
  standardDeviation,
  variance,
} from "./statistics.ts";

Deno.test(mean.name, async (t) => {
  await t.step("should return the mean of an array of numbers", () => {
    const xs = [1, 2, 3, 4, 5];
    const expected = 3;
    const actual = mean(xs);
    assertEquals(actual, expected);
  });
});

Deno.test(median.name, async (t) => {
  await t.step("handles odd length", () => {
    assertEquals(median([3, 1, 2]), 2);
  });

  await t.step("handles even length", () => {
    assertEquals(median([1, 2, 3, 4]), 2.5);
  });
});

Deno.test(variance.name, () => {
  assertAlmostEquals(variance([1, 2, 3, 4]), 1.6666666667, 1e-9);
});

Deno.test(standardDeviation.name, () => {
  assertAlmostEquals(standardDeviation([1, 2, 3, 4]), Math.sqrt(1.6666666667), 1e-9);
});

Deno.test(correlation.name, () => {
  const xs = [1, 2, 3, 4, 5];
  const ys = [2, 4, 6, 8, 10];
  assertAlmostEquals(correlation(xs, ys), 1, 1e-12);
});
