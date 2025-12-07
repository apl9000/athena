import { assertAlmostEquals, assertEquals } from "@std/assert";
import {
  dotProduct,
  euclideanDistance,
  identityMatrix,
  vectorAddition,
  vectorMean,
} from "./linear_algebra.ts";

Deno.test("vectorAddition adds element-wise", () => {
  assertEquals(vectorAddition([1, 2, 3], [4, 5, 6]), [5, 7, 9]);
});

Deno.test("dotProduct multiplies and sums", () => {
  assertEquals(dotProduct([1, 2, 3], [4, 5, 6]), 32);
});

Deno.test("distance computes Euclidean distance", () => {
  assertAlmostEquals(euclideanDistance([0, 0], [3, 4]), 5);
});

Deno.test("vectorMean averages vectors", () => {
  assertEquals(vectorMean([[1, 1], [3, 3]]), [2, 2]);
});

Deno.test("identityMatrix builds correct diagonal", () => {
  assertEquals(identityMatrix(3), [
    [1, 0, 0],
    [0, 1, 0],
    [0, 0, 1],
  ]);
});
