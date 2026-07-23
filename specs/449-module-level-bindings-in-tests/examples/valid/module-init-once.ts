// Module initializers run exactly once, before the first test block, in
// declaration order — not once per test.
let initRuns = 0;

function bump(): int {
  initRuns = initRuns + 1;
  return initRuns;
}

const first = bump();
const one = 1;
const two = one + 1;
const three = two + 1;

test("initializers already ran", () => {
  expect(initRuns == 1);
  expect(first == 1);
  expect(three == 3);
});

test("initializers did not run again", () => {
  expect(initRuns == 1);
  expect(first == 1);
  expect(three == 3);
});
