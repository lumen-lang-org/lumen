function boom(): void {
  throw new Error("kaput");
}

test("throws", () => {
  boom();
});
