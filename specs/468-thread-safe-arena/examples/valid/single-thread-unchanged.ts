// The other half of spec 468: a program with one thread must behave exactly as
// it did. Nested try, a rethrow caught one level up, a catch after a deep
// unwind, and the depth counter restored well enough that the next throw still
// reports correctly. Nothing here is about threads -- it is here so that moving
// the state onto the thread cannot quietly change the single-threaded answer.
function inner(tag: string): string { throw new Error("inner:" + tag); }

function middle(tag: string): string {
  try {
    return inner(tag);
  } catch (e) {
    throw new Error("middle(" + e.message + ")");
  }
}

function outer(tag: string): string {
  try {
    return middle(tag);
  } catch (e) {
    return "outer[" + e.message + "]";
  }
}

function deep(n: int): int {
  if (n == 0) { throw new Error("floor"); }
  return deep(n - 1) + 1;
}

console.log(outer("one"));
console.log(outer("two"));

let after = "unset";
try {
  const v = deep(24);
  after = "no-throw:" + v;
} catch (e) {
  after = "after-unwind:" + e.message;
}
console.log(after);

// A throw following the unwind still names itself, not the one before it.
try {
  const w = inner("last");
  console.log("unreachable:" + w);
} catch (e) {
  console.log("last:" + e.message);
}

const r = Math.random();
console.log(r >= 0 && r < 1);
