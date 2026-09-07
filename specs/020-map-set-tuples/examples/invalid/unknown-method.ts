// Map.clear() (this fixture's original example) was intentionally
// implemented since this fixture was written (spec 088) and is no longer
// unknown -- entries() is a genuinely still-unsupported Map method
// (lumen_check_methods.zig's mapMethod covers clear/set/get/has/delete/
// keys/values/forEach, not entries).
let m: Map<string, int> = new Map<string, int>();
m.entries();
