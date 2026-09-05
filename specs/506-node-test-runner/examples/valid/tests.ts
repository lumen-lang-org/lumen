import { twice } from "./tests_helper.ts";

function add(a: int, b: int): int { return a + b; }
const BASE: int = 10;

test("add sums", () => {
  expect(add(2, 3)).toBe(5);
  expect(add(2, 3) == 5);
});

test("module bindings are visible", () => {
  expect(add(BASE, 1)).toEqual(11);
});

test("an imported function works; the module's own tests stay home", () => {
  expect(twice(BASE)).toBe(20);
});
