/**
 * Statistics module
 */
import { assert } from "@std/assert/assert";
import { INVALID_ARGUMENT_ERROR, SAME_LENGTH_ERROR } from "./errors.ts";
import { dotProduct, sumOfSquares } from "./linear_algebra.ts";

/**
 * Returns the mean of an array of numbers.
 * @param xs {number[]} - An array of numbers
 * @returns {number} - The mean of the array
 */
export const mean = (xs: number[]): number => {
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR);
  return xs.reduce((acc, value) => (acc += value), 0) / xs.length;
};

const _medianOdd = (xs: number[]): number => {
  // If len(xs) is odd, the median function is the middle element
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR);
  return xs.sort((a, b) => a - b)[Math.trunc(xs.length / 2)];
};

const _medianEven = (xs: number[]): number => {
  // If len(xs) is even, it's the average of the middle two elements
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR);
  const sorted = xs.sort((a, b) => a - b);
  const mid = Math.trunc(xs.length / 2);
  return (sorted[mid - 1] + sorted[mid]) / 2;
};

/**
 * Returns the median of an array of numbers.
 * @param v {number[]} - An array of numbers
 * @returns {number} - The median of the array
 */
export const median = (v: number[]): number => {
  // Finds the middle-most value of v
  assert(v.length > 0, INVALID_ARGUMENT_ERROR);
  return v.length % 2 === 0 ? _medianEven(v) : _medianOdd(v);
};

/**
 * Returns the pth-percentile value of xs
 * @param xs {number[]} - An array of numbers
 * @param p {number} - The percentile value
 * @returns {number} - The pth-percentile value of xs
 */
export const quartile = (xs: number[], p: number): number => {
  // Returns the pth-percentile value of xs
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR);
  assert(p > 0 && p <= 1, INVALID_ARGUMENT_ERROR);
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

/**
 * Returns a list of the most common value(s)
 * @param xs {number[]} - An array of numbers
 * @returns {number[]} - A list of the most common value(s)
 */
export const mode = (xs: number[]): number[] => {
  // Returns a list of the most common value(s)
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR);
  const counted = xs.reduce((acc, value) => {
    !acc[value] ? (acc[value] = 1) : (acc[value] += 1);
    return acc;
  }, {} as { [v: number]: number });
  const max = _findMax(Object.values(counted));
  const mode: number[] = [];
  Object.keys(counted).forEach(
    (value: string) =>
      counted[Number(value)] === max && mode.push(Number(value)),
  );
  return mode;
};

/**
 * Returns the range of an array of numbers
 * @param xs {number[]} - An array of numbers
 * @returns {number} - The range of the array
 */
export const range = (xs: number[]): number => {
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR);
  return _findMax(xs) - _findMin(xs);
};

/**
 * Returns the deviation of an array of numbers from its mean
 * @param xs {number[]} - An array of numbers
 * @returns {number[]} - The deviation of the array from its mean
 */
export const deviationMean = (xs: number[]): number[] => {
  //Translate xs by subtracting its mean (so the result has mean 0)
  assert(xs.length > 0, INVALID_ARGUMENT_ERROR);
  const xBar = mean(xs);
  return xs.map((x) => x - xBar);
};

/**
 * Returns the variance of an array of numbers
 * @param xs {number[]} - An array of numbers
 * @returns {number} - The variance of the array
 */
export const variance = (xs: number[]): number => {
  assert(xs.length >= 2, INVALID_ARGUMENT_ERROR);
  return sumOfSquares(deviationMean(xs)) / (xs.length - 1);
};

/**
 * Returns the standard deviation of an array of numbers
 * @param xs {number[]} - An array of numbers
 * @returns {number} - The standard deviation of the array
 */
export const standardDeviation = (xs: number[]): number => {
  assert(xs.length >= 2, INVALID_ARGUMENT_ERROR);
  return Math.sqrt(variance(xs));
};

/**
 * Returns the interquartile range of an array of numbers
 * @param xs {number[]} - An array of numbers
 * @returns {number} - The interquartile range of the array
 */
export const interQuartileRange = (xs: number[]): number => {
  // Returns the difference between the 75%-tile & 25%-tile
  return quartile(xs, 0.75) - quartile(xs, 0.25);
};

/**
 * Returns the sample covariance between two data sets.
 * @param xs array of numbers
 * @param ys array of numbers (must match xs length)
 */
export const covariance = (xs: number[], ys: number[]): number => {
  assert(xs.length === ys.length, SAME_LENGTH_ERROR);
  return dotProduct(deviationMean(xs), deviationMean(ys)) / (xs.length - 1);
};

/**
 * Returns the Pearson correlation coefficient in the range [-1, 1].
 * @param xs array of numbers
 * @param ys array of numbers (must match xs length)
 */
export const correlation = (xs: number[], ys: number[]): number => {
  const standardDeviationOfXs = standardDeviation(xs);
  const standardDeviationOfYs = standardDeviation(ys);
  return standardDeviationOfXs > 0 && standardDeviationOfYs > 0
    ? covariance(xs, ys) / standardDeviationOfXs / standardDeviationOfYs
    : 0;
};
