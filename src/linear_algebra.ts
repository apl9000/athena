import { commonErrors, trueOrThrow } from "./errors.ts";

/** A one-dimensional array of numbers. */
export type Vector = number[];

/** A two-dimensional array of numbers, represented as an array of row vectors. */
export type Matrix = Vector[];

/** Adds two vectors element-wise. */
export const vectorAddition = (v: Vector, w: Vector): Vector => {
  trueOrThrow(v.length === w.length, commonErrors.SAME_LENGTH_ERROR);
  return v.map((vi, index) => vi + w[index]);
};

/** Subtracts two vectors element-wise. */
export const vectorSubtraction = (v: Vector, w: Vector): Vector => {
  trueOrThrow(v.length === w.length, commonErrors.SAME_LENGTH_ERROR);
  return v.map((vi, index) => vi - w[index]);
};

/** Sums a list of vectors element-wise. */
export const vectorSum = (vectors: Vector[]): Vector => {
  trueOrThrow(vectors.length > 0, commonErrors.MIN_ARGUMENT_ERROR);
  const vectorLength = vectors[0].length;
  return vectors.reduce((acc, vector) => {
    trueOrThrow(vectorLength === vector.length, commonErrors.SAME_LENGTH_ERROR);
    return vectorAddition(acc, vector);
  }, new Array(vectorLength).fill(0) as Vector);
};

/** Multiplies every element of a vector by a scalar. */
export const scalarMultiply = (c: number, v: Vector): Vector => {
  return v.map((vi) => vi * c);
};

/** Returns the element-wise mean of a list of vectors. */
export const vectorMean = (vectors: Vector[]): Vector => {
  trueOrThrow(vectors.length > 0, commonErrors.MIN_ARGUMENT_ERROR);
  return scalarMultiply(1 / vectors.length, vectorSum(vectors));
};

/** Computes the dot product of two vectors. */
export const dotProduct = (v: Vector, w: Vector): number => {
  trueOrThrow(v.length === w.length, commonErrors.SAME_LENGTH_ERROR);
  return v.reduce((acc, vi, i) => (acc += vi * w[i]), 0);
};

/** Returns the sum of squares of a vector. */
export const sumOfSquares = (v: Vector): number => {
  return dotProduct(v, v);
};

/** Returns the Euclidean magnitude of a vector. */
export const vectorMagnitude = (v: Vector): number => {
  return Math.sqrt(sumOfSquares(v));
};

/** Returns the squared Euclidean distance between two vectors. */
export const squaredDistance = (v: Vector, w: Vector): number => {
  return sumOfSquares(vectorSubtraction(v, w));
};

/** Returns the Euclidean distance between two vectors. */
export const euclideanDistance = (v: Vector, w: Vector): number => {
  return Math.sqrt(squaredDistance(v, w));
};

/** Returns the number of rows and columns in a matrix. */
export const matrixShape = (A: Matrix): { rows: number; columns: number } => {
  return {
    rows: A.length,
    columns: A[0]?.length || 0,
  };
};

/** Returns the i-th row of a matrix. */
export const matrixRow = (A: Matrix, i: number): Vector => {
  return A[i];
};

/** Returns the j-th column of a matrix. */
export const matrixColumn = (A: Matrix, j: number): Vector => {
  return A.map((row) => row[j]);
};

/**
 * Builds a matrix whose (i, j)-th entry is provided by fn(i, j).
 */
export const matrix = (
  rows: number,
  columns: number,
  fn: (i: number, j: number) => number,
): Matrix => {
  trueOrThrow(rows > 0 && columns > 0, commonErrors.INVALID_ARGUMENT_ERROR);
  return Array.from(
    { length: rows },
    (_row, i) => Array.from({ length: columns }, (_col, j) => fn(i, j)),
  );
};

/** Creates an n x n identity matrix. */
export const identityMatrix = (n: number): Matrix => {
  trueOrThrow(n > 0, commonErrors.INVALID_ARGUMENT_ERROR);
  return matrix(n, n, (i, j) => (i === j ? 1 : 0));
};
