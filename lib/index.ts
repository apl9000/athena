import * as Geometry from "./geometry/index.ts";
import * as LinearAlgebra from "./linear_algebra/index.ts";
import * as statistics from "./statistics/index.ts";

export default (function main() {
  return {
    Geometry,
    LinearAlgebra,
    ...statistics,
  }
})();
