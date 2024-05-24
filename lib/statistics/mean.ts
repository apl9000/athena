import { assert } from "@std/assert/assert";
import { assertEquals } from "@std/assert";
import { INVALID_ARGUMENT_ERROR } from "../errors/index.ts";

export const mean = (xs: number[]): number => {
  // returns the mean
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR);
  return xs.reduce((acc, value) => (acc += value), 0) / xs.length;
};


