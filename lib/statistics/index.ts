import { assert } from "@std/assert/assert";
import { INVALID_ARGUMENT_ERROR, SAME_LENGTH_ERROR } from "../errors/index.ts";
import { dotProduct, sumOfSquares } from "../linear_algebra/index.ts";

export const mean = (xs: number[]): number => {
  // returns the mean
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR.message);
  return xs.reduce((acc, value) => (acc += value), 0) / xs.length;
};

const _medianOdd = (xs: number[]): number => {
  // If len(xs) is odd, the median function is the middle element
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR.message);
  return xs.sort((a, b) => a - b)[Math.trunc(xs.length / 2)];
};

const _medianEven = (xs: number[]): number => {
  // If len(xs) is even, it's the average of the middle two elements
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR.message);
  const sorted = xs.sort((a, b) => a - b);
  const mid = Math.trunc(xs.length / 2);
  return (sorted[mid - 1] + sorted[mid]) / 2;
};

export const median = (v: number[]): number => {
  // Finds the middle-most value of v
  assert(v.length > 0, INVALID_ARGUMENT_ERROR.message);
  return v.length % 2 === 0 ? _medianEven(v) : _medianOdd(v);
};

export const quartile = (xs: number[], p: number): number => {
  // Returns the pth-percentile value of xs
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR.message);
  assert(p > 0 && p <= 1, INVALID_ARGUMENT_ERROR.message);
  return xs.sort((a, b) => a - b)[p * xs.length];
};

const _findMax = (xs: number[]): number => {
  let max = -Infinity;
  for (let i = 0; i < xs.length; i++) {
    if (xs[i] > max) {
      max = xs[i];
    }
  }
  return max;
};

const _findMin = (xs: number[]): number => {
  let min = Infinity;
  for (let i = 0; i < xs.length; i++) {
    if (xs[i] < min) {
      min = xs[i];
    }
  }
  return min;
};

export const mode = (xs: number[]): number[] => {
  // Returns a list of the most common value(s)
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR.message);
  const counted = xs.reduce((acc, value) => {
    !acc[value] ? (acc[value] = 1) : (acc[value] += 1);
    return acc;
  }, {} as { [v: number]: number });
  const max = _findMax(Object.values(counted));
  const mode: number[] = [];
  Object.keys(counted).forEach(
    (value: any) => counted[value] === max && mode.push(Number(value)),
  );
  return mode;
};

export const dataRange = (xs: number[]): number => {
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR.message);
  return _findMax(xs) - _findMin(xs);
};

export const deviationMean = (xs: number[]): number[] => {
  //Translate xs by subtracting its mean (so the result has mean 0)
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR.message);
  const xBar = mean(xs);
  return xs.map((x) => x - xBar);
};

export const variance = (xs: number[]): number => {
  assert(xs.length >= 2, INVALID_ARGUMENT_ERROR.message);
  return sumOfSquares(deviationMean(xs)) / (xs.length - 1);
};

export const standardDeviation = (xs: number[]): number => {
  assert(xs.length >= 2, INVALID_ARGUMENT_ERROR.message);
  return Math.sqrt(variance(xs));
};

export const interQuartileRange = (xs: number[]): number => {
  // Returns the difference between the 75%-tile & 25%-tile
  return quartile(xs, 0.75) - quartile(xs, 0.25);
};

export const covariance = (xs: number[], ys: number[]): number => {
  // Covariance measures how 2 variables vary in tandem from their means
  assert(xs.length === ys.length, SAME_LENGTH_ERROR.message);
  return dotProduct(deviationMean(xs), deviationMean(ys)) / (xs.length - 1);
};

export const correlation = (xs: number[], ys: number[]): number => {
  // Measures how much xs & ys vary in tandem about their means
  const standardDeviationOfXs = standardDeviation(xs);
  const standardDeviationOfYs = standardDeviation(ys);
  return standardDeviationOfXs > 0 && standardDeviationOfYs > 0
    ? covariance(xs, ys) / standardDeviationOfXs / standardDeviationOfYs
    : 0;
};
