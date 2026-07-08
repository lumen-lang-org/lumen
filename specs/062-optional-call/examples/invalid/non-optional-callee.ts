// `?.()` requires the callee's static type to be optional. A plain, non-
// optional `int` is rejected outright.
let x: int = 5;
x?.();
