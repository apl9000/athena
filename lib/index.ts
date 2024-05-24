import * as Geometry from "./geometry/index.ts";
import * as LinearAlgebra from "./linear_algebra/index.ts";
import * as Statistics from "./statistics/index.ts";

export { Geometry, LinearAlgebra, Statistics };

console.log("Hello, world!");
console.log(Geometry.rectangleArea(10, 20));
console.log(LinearAlgebra.vectorAddition([1, 2, 3], [4, 5, 6]));
console.log(Statistics.mean([1, 2, 3, 4, 5]));
console.log("Goodbye, world!");