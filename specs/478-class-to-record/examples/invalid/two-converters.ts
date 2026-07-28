// Two generic functions both claim to turn any class into a `Box`. Which one
// this list meant is not the compiler's to guess, so it says so and names both.

type Box = {
  name: string,
};

function boxed<T>(c: T): Box {
  let b: Box = { name: Class.nameOf(c) };
  return b;
}

function wrapped<T>(c: T): Box {
  let b: Box = { name: "wrapped " + Class.nameOf(c) };
  return b;
}

class A {
  n: int = 1;
}

function main(): void {
  let boxes: Box[] = [new A()];
  console.log(boxes[0].name + boxed(new A()).name + wrapped(new A()).name);
}

main();
