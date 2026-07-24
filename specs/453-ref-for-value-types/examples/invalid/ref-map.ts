// a map is already a heap pointer, so Ref adds nothing and stays rejected.
function f(m: Ref<Map<string, int>>): void {
  m.set("a", 1);
}
let m = new Map<string, int>();
f(m);
