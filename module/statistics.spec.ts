import { assertEquals } from "@std/assert";
import { mean } from "./statistics.ts";

Deno.test(mean.name, async (t) => {
  await t.step("should return the mean of an array of numbers", () => {
    const xs = [1, 2, 3, 4, 5];
    const expected = 3;
    const actual = mean(xs);
    assertEquals(actual, expected);
  });
});