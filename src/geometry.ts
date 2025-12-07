import { assert } from "@std/assert/assert";
import { INVALID_ARGUMENT_ERROR, MIN_ARGUMENT_ERROR } from "./errors.ts";

// CIRCLE
/** Circle properties derived from any one of radius, area, or circumference. */
export type Circle = {
  radius: number;
  area: number;
  circumference: number;
};

/** Optional inputs for computing a circle. */
export type CircleArgs = Partial<Circle>;

/** Returns a circle's area given its radius. */
export const circleArea = (r: number): number => {
  assert(r > 0, INVALID_ARGUMENT_ERROR);
  return Math.PI * Math.pow(r, 2);
};

/** Returns a circle's circumference given its radius. */
export const circleCircumference = (r: number): number => {
  assert(r > 0, INVALID_ARGUMENT_ERROR);
  return 2 * Math.PI * r;
};

// The
/**
 * Computes full circle properties from any one of: radius, circumference, or area.
 */
export const circle = ({ radius, circumference, area }: CircleArgs): Circle => {
  assert(!!(radius || circumference || area), MIN_ARGUMENT_ERROR);

  if (circumference) {
    assert(circumference > 0, INVALID_ARGUMENT_ERROR);
    radius = circumference / (2 * Math.PI);
  }

  if (area) {
    assert(area > 0, INVALID_ARGUMENT_ERROR);
    radius = Math.sqrt(area / Math.PI);
  }

  if (!radius || radius <= 0) {
    throw new Error(INVALID_ARGUMENT_ERROR);
  }

  circumference = circumference || circleCircumference(radius);
  area = area || circleArea(radius);

  return {
    radius,
    circumference,
    area,
  };
};

// SQUARE
/** Square properties derived from length, area, or perimeter. */
export type Square = {
  length: number;
  area: number;
  perimeter: number;
};

/** Optional inputs for computing a square. */
export type SquareArgs = Partial<Square>;

/** Returns a square's area given its side length. */
export const squareArea = (l: number): number => {
  assert(l > 0, INVALID_ARGUMENT_ERROR);
  return Math.pow(l, 2);
};

/** Returns a square's perimeter given its side length. */
export const squarePerimeter = (l: number): number => {
  assert(l > 0, INVALID_ARGUMENT_ERROR);
  return l * 4;
};

/** Computes full square properties from length, area, or perimeter. */
export const square = ({ length, area, perimeter }: SquareArgs): Square => {
  assert(!!(length || area || perimeter), MIN_ARGUMENT_ERROR);

  if (area) {
    assert(area > 0, INVALID_ARGUMENT_ERROR);
    length = Math.sqrt(area);
  }

  if (perimeter) {
    assert(perimeter > 0, INVALID_ARGUMENT_ERROR);
    length = perimeter / 4;
  }

  if (!length || length <= 0) {
    throw new Error(INVALID_ARGUMENT_ERROR);
  }

  perimeter = perimeter || squarePerimeter(length);
  area = area || squareArea(length);

  return {
    length,
    area,
    perimeter,
  };
};

// RECTANGLE
/** Rectangle properties derived from length and width. */
export type Rectangle = {
  length: number;
  width: number;
  area: number;
  perimeter: number;
};

export type RectangleArgs = {
  length: number;
  width: number;
};

/** Returns a rectangle's perimeter given length and width. */
export const rectanglePerimeter = (l: number, w: number): number => {
  assert(l > 0 && w > 0, INVALID_ARGUMENT_ERROR);
  return 2 * (w + l);
};

/** Returns a rectangle's area given length and width. */
export const rectangleArea = (l: number, w: number): number => {
  assert(l > 0 && w > 0, INVALID_ARGUMENT_ERROR);
  return w * l;
};

/** Computes full rectangle properties from length and width. */
export const rectangle = ({ length, width }: RectangleArgs): Rectangle => {
  assert(length > 0 && width > 0, INVALID_ARGUMENT_ERROR);
  return {
    length,
    width,
    area: rectangleArea(length, width),
    perimeter: rectanglePerimeter(length, width),
  };
};
