import * as LinearAlgebra from './index';
import { SAME_LENGTH_ERROR } from '../errors/index';

describe('LinearAlgebra', () => {
	describe('fn: vectorAddition', () => {
		test('should add to vectors together', () => {
			expect(LinearAlgebra.vectorAddition([1, 2, 3], [5, 6, 7])).toBe([
				6,
				8,
				10
			]);
    });
    
		test('should throw if vectors are not the same length', () => {
			expect(LinearAlgebra.vectorAddition([1, 2], [5, 4, 6])).toThrowError(
				SAME_LENGTH_ERROR
			);
		});
	});
});
