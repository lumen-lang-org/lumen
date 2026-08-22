// Map and Set now carry a per-instance race guard (an atomic flag checked
// on every op) and copy `[]const u8` keys/values on insert instead of
// storing the caller's slice as-is. Neither should be visible to a
// single-threaded program: no other thread ever touches the guard, so it
// only ever sees itself, and every string here already outlives the Map
// that holds it, so the copy changes nothing observable.
let m = new Map<string, int>();
m.set("a", 1);
m.set("b", 2);
m.set("a", 3);
console.log(`get_a=${m.get("a") ?? -1}`);
console.log(`get_b=${m.get("b") ?? -1}`);
console.log(`has_c=${m.has("c")}`);
console.log(`size=${m.size}`);
m.delete("a");
console.log(`after_delete_size=${m.size}`);
console.log(`after_delete_has_a=${m.has("a")}`);
m.forEach((v: int, k: string) => { console.log(`each ${k}=${v}`); });

let s = new Set<string>();
s.add("x");
s.add("y");
s.add("x");
console.log(`set_size=${s.size}`);
console.log(`has_x=${s.has("x")}`);
s.delete("x");
console.log(`after_delete_set_size=${s.size}`);
console.log(`after_delete_has_x=${s.has("x")}`);
