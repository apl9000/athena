import { assertAlmostEquals, assertEquals, assertThrows } from "@std/assert";
import { circle, circleArea, rectangle, square } from "./geometry.ts";

Deno.test("circleArea uses radius", () => {
  assertAlmostEquals(circleArea(2), Math.PI * 4);
});

Deno.test("circle derives from circumference", () => {
  const c = circle({ circumference: 2 * Math.PI * 3 });
  assertAlmostEquals(c.radius, 3);
  assertAlmostEquals(c.area, Math.PI * 9);
});

Deno.test("square derives from perimeter", () => {
  const s = square({ perimeter: 20 });
  assertEquals(s.length, 5);
  assertEquals(s.area, 25);
});

Deno.test("rectangle validates positive dimensions", () => {
  assertThrows(() => rectangle({ length: 0, width: 2 }));
});
