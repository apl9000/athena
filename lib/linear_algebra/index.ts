import * as assert from 'assert';
import { SAME_LENGTH_ERROR, INVALID_ARGUMENT_ERROR } from '../errors/index';

// TYPES
export type Vector = number[];
export type Matrix = Vector[];

// Vector Operations
export const vectorAddition = (v: Vector, w: Vector): Vector => {
	// Adds corresponding elements
	assert(v.length === w.length, SAME_LENGTH_ERROR);
	return v.map((vi, index) => vi + w[index]);
};

export const vectorSubtraction = (v: Vector, w: Vector): Vector => {
	// Subtracts corresponding elements
	assert(v.length === w.length, SAME_LENGTH_ERROR);
	return v.map((vi, index) => vi - w[index]);
};

export const vectorSum = (vectors: Vector[]): Vector => {
	// Sums all corresponding elements
	assert(vectors.length, INVALID_ARGUMENT_ERROR);
	const vectorLength = vectors[0].length;
	return vectors.reduce((acc, vector) => {
		assert(vectorLength === vector.length, SAME_LENGTH_ERROR);
		return vectorAddition(acc, vector);
	}, new Array(vectorLength).fill(0) as Vector);
};

export const scalarMultiply = (c: number, v: Vector): Vector => {
	// Multiplies every element by a scalar
	return v.map((vi) => vi * c);
};

export const vectorMean = (vectors: Vector[]): Vector => {
	// Returns the element-wise average
	assert(vectors.length, INVALID_ARGUMENT_ERROR);
	return scalarMultiply(1 / vectors.length, vectorSum(vectors));
};

export const dotProduct = (v: Vector, w: Vector): number => {
	// Returns v_1 * w_1 + ... + v_n * v_n
	assert(v.length === w.length, SAME_LENGTH_ERROR);
	return v.reduce((acc, vi, i) => (acc += vi * w[i]), 0);
};

export const sumOfSquares = (v: Vector): number => {
	// Returns v_1 * v_1 + ... + v_n * v_n
	return dotProduct(v, v);
};

export const vectorMagnitude = (v: Vector): number => {
	// Returns the magnitude (or length) of the vector
	return Math.sqrt(sumOfSquares(v));
};

export const squaredDistance = (v: Vector, w: Vector): number => {
	// Returns (v_1 - w_1)^2 + ... + (v_n - w_n)^2
	return sumOfSquares(vectorSubtraction(v, w));
};

export const distance = (v: Vector, w: Vector): number => {
	// Returns the distance between v & w
	return Math.sqrt(squaredDistance(v, w));
};

// Matrix
export const matrixShape = (A: Matrix): { rows: number; columns: number } => {
	// Returns (# of rows & columns of matrix)
	return {
		rows: A.length,
		columns: A[0].length || 0
	};
};

export const matrixRow = (A: Matrix, i: number): Vector => {
	// Returns the i-th row of A (as a Vector)
	return A[i];
};

export const matrixColumn = (A: Matrix, j: number): Vector => {
	// Returns j-th column of A (as a Vector);
	return A.map((row) => row[j]);
};

export const matrix = (
	rows: number,
	columns: number,
	fn: (i: number, j: number) => number
): Matrix => {
	// Returns a num_rows x num_cols matrix
	//  whose (i, j)-th entry is fn(i, j)
	const A = new Array(rows).fill(new Array(columns).fill(0));
	for (let i = 0; i < rows; i++) {
		for (let j = 0; j < rows; j++) {
			A[i][j] = fn(i, j);
		}
	}
	return A;
};

export const identityMatrix = (n: number) => {
	// Returns the n * n identity matrix
	return matrix(n, n, (i, j) => (i === j ? 1 : 0));
};
