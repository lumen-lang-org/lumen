// Reproduction 1: a module-level `let`/`const` referenced directly from a
// test block. This was a compile error ("use of undeclared identifier").
let greeting = "hello";
const answer = 42;

test("module-level let inside a test block", () => {
  expect(greeting == "hello");
  expect(answer == 42);
});
