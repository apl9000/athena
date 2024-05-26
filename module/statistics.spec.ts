import { assertEquals } from "@std/assert";
import * as statistics from "./statistics.ts";

Deno.test("Statistics Module", async (t) => {
  await t.step(
    `fn: ${statistics.mean.name} - should return the mean of an array of numbers`,
    () => {
      const xs = [1, 2, 3, 4, 5];
      const expected = 3;
      const actual = statistics.mean(xs);
      assertEquals(actual, expected);
    },
  );

  await t.step(
    `fn: ${statistics.median.name} - should return the median of an array of numbers`,
    () => {
      const xs = [1, 2, 3, 4, 5];
      const expected = 3;
      const actual = statistics.median(xs);
      assertEquals(actual, expected);
    },
  );

  const quartileTestCases = [
    [0.5, 3],
    [0.25, 2],
    [0.75, 4],
    [0.1, 1],
    [0.9, 5],
  ];
  for (const [p, expected] of quartileTestCases) {
    await t.step(
      `fn: ${statistics.quartile.name} - should return the pth-percentile value of xs`,
      () => {
        const xs = [1, 2, 3, 4, 5];
        const actual = statistics.quartile(xs, p);
        assertEquals(actual, expected);
      },
    );
  }
});
