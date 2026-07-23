// Reproduction 2: a module-level binding reached through a function. This
// compiled but read uninitialized memory, so the test passed against garbage.
let g = "hello";
let n = 42;

function readG(): string {
  return g;
}

function readN(): int {
  return n;
}

test("what module-level values actually hold in a test", () => {
  console.log(`g=[${readG()}] n=${readN()}`);
  expect(readG() == "hello");
  expect(readN() == 42);
});
