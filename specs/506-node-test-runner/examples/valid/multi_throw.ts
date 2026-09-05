function boom(): void {
  throw new Error("kaput");
}

test("throws", () => {
  boom();
});

test("still runs", () => {
  expect(1 + 1).toBe(2);
});
