// An array method nested inside a string method, and the reverse.
const s = "a,b,c";
console.log(s.substring(0, s.split(",").length));
const w: string[] = ["aa", "bbb", "c"];
console.log(w.filter((x: string): boolean => x.substring(0, 1).indexOf("b") >= 0).length);
