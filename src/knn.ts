import type { Vector } from "./linear_algebra.ts";
import { euclideanDistance } from "./linear_algebra.ts";

/** Performs a majority vote on an array of labels, resolving ties by removing the last label and re-voting. */
const majorityVote = (labels: string[]): string => {
  const labelCounts: { [key: string]: number } = {};
  for (const label of labels) {
    labelCounts[label] = (labelCounts[label] || 0) + 1;
  }

  const labelCountsSorted = Object.entries(labelCounts).sort((a, b) =>
    b[1] - a[1]
  );
  const [winnerLabel, winnerCount] = labelCountsSorted[0];
  const numberOfWinners =
    labelCountsSorted.filter(([_, count]) => count === winnerCount).length;

  if (numberOfWinners === 1) {
    return winnerLabel;
  } else {
    return majorityVote(labels.slice(0, -1));
  }
};
/**
 * Classifies a vector using the k-Nearest Neighbors algorithm.
 * @param k The number of nearest neighbors to consider.
 * @param dataSet An array of tuples where each tuple contains a vector and its corresponding label.
 * @param labels {string[]} An array of possible labels .
 * @param inputVector The vector to classify.
 * @returns {string} The predicted label for the input vector.
 */
export const kNN = (
  k: number = 3,
  dataSet: Vector[],
  labels: string[],
  inputVector: Vector,
) => {
  return majorityVote(
    dataSet
      .map((dataVector, index) => ({
        label: labels[index],
        distance: euclideanDistance(dataVector, inputVector),
      }))
      .sort((a, b) => a.distance - b.distance)
      .slice(0, k)
      .map((item) => item.label),
  );
};
