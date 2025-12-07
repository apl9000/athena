/**
 * Common error messages and utility functions for error handling.
 * @module
 */

/** Error message used when no arguments are provided but at least one is required. */
const MIN_ARGUMENT_ERROR =
  "A minimum of 1 argument must be passed to the function";

/** Error message used when an argument fails validation. */
const INVALID_ARGUMENT_ERROR = "Invalid function argument";

/** Error message used when vectors must have identical length. */
const SAME_LENGTH_ERROR = "Vectors must be of the same length";

export const commonErrors = {
  MIN_ARGUMENT_ERROR,
  INVALID_ARGUMENT_ERROR,
  SAME_LENGTH_ERROR,
};

/** Throws an Error with the provided message when condition is falsy. */
export const trueOrThrow: (
  condition: boolean,
  message: string,
) => asserts condition = (
  condition,
  message,
) => {
  if (!condition) throw new Error(message);
};
