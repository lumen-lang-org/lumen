function add(a: int, b: int): int {
  return a + b;
}

test("adds", () => {
  expect(add(2, 2)).toBe(4);
});

test("logs while running", () => {
  console.log("checking");
  expect(true);
});

test("fails", () => {
  expect(add(1, 2)).toBe(4);
});
