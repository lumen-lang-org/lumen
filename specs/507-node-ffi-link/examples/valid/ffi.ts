// @link ./shim.o
// @link-node ./shim.mjs
declare function shim_add(a: int, b: int): int;
declare function shim_greet(name: string): string;

console.log(shim_add(40, 2));
console.log(shim_greet("lumen"));
