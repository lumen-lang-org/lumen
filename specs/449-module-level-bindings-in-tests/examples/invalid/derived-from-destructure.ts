// A promoted binding whose initializer reads a module-level destructuring
// binding cannot be initialized before tests run: rejected in test mode rather
// than left to read uninitialized memory (spec 449).
const pair: [int, int] = [1, 2];
const [dx, dy] = pair;
const sum = dx + dy;

test("derived reads a destructured binding", () => {
  expect(sum == 3);
});
