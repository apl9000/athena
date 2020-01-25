import * as assert from 'assert';
import { SAME_LENGTH_ERROR } from '../errors/index';
import { Vector } from './types';

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

// export const vectorSum = (vectors: Vector[]): Vector => {
// 	// Sums all corresponding elements

// };
