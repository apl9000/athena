import { assert } from "@std/assert/assert";
import { assertEquals } from "jsr:@std/assert";
import { INVALID_ARGUMENT_ERROR } from "../errors/index.ts";

export const mean = (xs: number[]): number => {
  // returns the mean
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR.message);
  return xs.reduce((acc, value) => (acc += value), 0) / xs.length;
};

Deno.test(mean.name, async (t) => {
  await t.step("should return the mean of an array of numbers", () => {
    const xs = [1, 2, 3, 4, 5];
    const expected = 3;
    const actual = mean(xs);
    assertEquals(actual, expected);
  });
});