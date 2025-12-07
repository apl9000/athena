/**
 * Geometry-related functions and types.
 * @module
 */
import { commonErrors, trueOrThrow } from "./errors.ts";

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
  trueOrThrow(r > 0, commonErrors.INVALID_ARGUMENT_ERROR);
  return Math.PI * Math.pow(r, 2);
};

/** Returns a circle's circumference given its radius. */
export const circleCircumference = (r: number): number => {
  trueOrThrow(r > 0, commonErrors.INVALID_ARGUMENT_ERROR);
  return 2 * Math.PI * r;
};

// The
/**
 * Computes full circle properties from any one of: radius, circumference, or area.
 */
export const circle = ({ radius, circumference, area }: CircleArgs): Circle => {
  trueOrThrow(
    !!(radius || circumference || area),
    commonErrors.MIN_ARGUMENT_ERROR,
  );

  if (circumference) {
    trueOrThrow(circumference > 0, commonErrors.INVALID_ARGUMENT_ERROR);
    radius = circumference / (2 * Math.PI);
  }

  if (area) {
    trueOrThrow(area > 0, commonErrors.INVALID_ARGUMENT_ERROR);
    radius = Math.sqrt(area / Math.PI);
  }

  if (!radius || radius <= 0) {
    throw new Error(commonErrors.INVALID_ARGUMENT_ERROR);
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
  trueOrThrow(l > 0, commonErrors.INVALID_ARGUMENT_ERROR);
  return Math.pow(l, 2);
};

/** Returns a square's perimeter given its side length. */
export const squarePerimeter = (l: number): number => {
  trueOrThrow(l > 0, commonErrors.INVALID_ARGUMENT_ERROR);
  return l * 4;
};

/** Computes full square properties from length, area, or perimeter. */
export const square = ({ length, area, perimeter }: SquareArgs): Square => {
  trueOrThrow(!!(length || area || perimeter), commonErrors.MIN_ARGUMENT_ERROR);

  if (area) {
    trueOrThrow(area > 0, commonErrors.INVALID_ARGUMENT_ERROR);
    length = Math.sqrt(area);
  }

  if (perimeter) {
    trueOrThrow(perimeter > 0, commonErrors.INVALID_ARGUMENT_ERROR);
    length = perimeter / 4;
  }

  if (!length || length <= 0) {
    throw new Error(commonErrors.INVALID_ARGUMENT_ERROR);
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
  trueOrThrow(l > 0 && w > 0, commonErrors.INVALID_ARGUMENT_ERROR);
  return 2 * (w + l);
};

/** Returns a rectangle's area given length and width. */
export const rectangleArea = (l: number, w: number): number => {
  trueOrThrow(l > 0 && w > 0, commonErrors.INVALID_ARGUMENT_ERROR);
  return w * l;
};

/** Computes full rectangle properties from length and width. */
export const rectangle = ({ length, width }: RectangleArgs): Rectangle => {
  trueOrThrow(length > 0 && width > 0, commonErrors.INVALID_ARGUMENT_ERROR);
  return {
    length,
    width,
    area: rectangleArea(length, width),
    perimeter: rectanglePerimeter(length, width),
  };
};
