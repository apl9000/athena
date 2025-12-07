import { assertEquals } from "@std/assert/assert-equals";
import { kNN } from "./knn.ts";

Deno.test(kNN.name, async (t) => {
  const dataSet = [
    [1, 2],
    [2, 3],
    [3, 3],
    [6, 5],
    [7, 7],
    [8, 6],
  ];
  const labels = ["A", "A", "A", "B", "B", "B"];

  await t.step("classifies input vector correctly", () => {
    const inputVector = [2, 2];
    const predictedLabel = kNN(3, dataSet, labels, inputVector);
    assertEquals(predictedLabel, "A");
  });

  await t.step("handles tie by removing last neighbor", () => {
    const inputVector = [5, 5];
    const predictedLabel = kNN(4, dataSet, labels, inputVector);
    assertEquals(predictedLabel, "B");
  });
});
