// Imported by tests.ts: its own test block must not run there (spec 012
// FR-007) -- it would fail if it did.
export function twice(n: int): int { return n * 2; }

test("a helper's test does not run from an importer", () => {
  expect(twice(1)).toBe(3);
});
