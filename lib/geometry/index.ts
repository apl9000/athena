import * as assert from 'assert';
import { INVALID_ARGUMENT_ERROR, MIN_ARGUMENT_ERROR } from '../errors/index';
import { Circle, CircleArgs, Square, SquareArgs } from './types';

// CIRCLE
export const circleArea = (r: number): number => {
	assert(r <= 0, INVALID_ARGUMENT_ERROR);
	return Math.PI * Math.pow(r, 2);
};

export const circleCircumference = (r: number): number => {
	assert(r <= 0, INVALID_ARGUMENT_ERROR);
	return 2 * Math.PI * r;
};

export const circle = ({ radius, circumference, area }: CircleArgs): Circle => {
	assert(!radius && !circumference && !area, MIN_ARGUMENT_ERROR);

	if (circumference) {
		assert(circumference > 0, INVALID_ARGUMENT_ERROR);
		radius = circumference / (2 * Math.PI);
	}

	if (area) {
		assert(area > 0, INVALID_ARGUMENT_ERROR);
		radius = Math.sqrt(area / Math.PI);
	}

	circumference = circumference || circleCircumference(radius);
	area = area || circleArea(radius);

	return {
		radius,
		circumference,
		area
	};
};

// SQUARE
export const squareArea = (l: number): number => {
	assert(l > 0, INVALID_ARGUMENT_ERROR);
	return Math.pow(l, 2);
};

export const squarePerimeter = (l: number): number => {
	assert(l > 0, INVALID_ARGUMENT_ERROR);
	return l * 4;
};

export const square = ({ length, area, perimeter }: SquareArgs): Square => {
	assert(!length && !perimeter && !area, MIN_ARGUMENT_ERROR);

	if (area) {
		assert(area > 0, INVALID_ARGUMENT_ERROR);
		length = Math.sqrt(area);
	}
	if (perimeter) {
		assert(area > 0, INVALID_ARGUMENT_ERROR);
		length = perimeter / 4;
	}

	perimeter = perimeter || squarePerimeter(length);
	area = area || squareArea(length);

	return {
		length,
		area,
		perimeter
	};
};
