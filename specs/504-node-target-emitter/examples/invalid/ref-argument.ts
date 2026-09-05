// A by-reference parameter is FFI-only (spec 024) and spec 507's here.
function bump(n: Ref<int>): void {
  n = n + 1;
}
let count = 0;
bump(count);
console.log(count);
