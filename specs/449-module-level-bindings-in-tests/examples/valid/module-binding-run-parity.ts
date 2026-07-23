// The same program under `lumen run`: top-level statements still execute in
// declaration order and print, exactly as before this fix.
let g = "hello";
let n = 42;

function readG(): string {
  return g;
}

function readN(): int {
  return n;
}

console.log(`g=[${readG()}] n=${readN()}`);

test("module state is also visible to the test block", () => {
  expect(readG() == "hello");
  expect(readN() == 42);
});
