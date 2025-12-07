import { assertEquals } from "@std/assert";
import { trueOrThrow } from "@apl/athena/errors";

Deno.test(trueOrThrow.name, async (test) => {
  await test.step("does not throw when condition is true", () => {
    let didThrow = false;
    try {
      trueOrThrow(true, "This should not throw");
    } catch (_e) {
      didThrow = true;
    }
    assertEquals(didThrow, false);
  });
  await test.step("throws an error when condition is false", () => {
    const errorMessage = "Test error message";
    let didThrow = false;
    try {
      trueOrThrow(false, errorMessage);
    } catch (e: unknown) {
      didThrow = true;
      assertEquals(e instanceof Error, true);
      if (e instanceof Error) {
        assertEquals(e.message, errorMessage);
      }
    }
    assertEquals(didThrow, true);
  });
});
