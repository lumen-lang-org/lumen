// Same rejection for a multi-declarator group (`let p = 1, q = 2;`), which also
// stays a `main` local and can't be replayed before tests (spec 449).
let p = 1, q = 2;
const total = p + q;

test("derived reads a multi-declarator group", () => {
  expect(total == 3);
});
