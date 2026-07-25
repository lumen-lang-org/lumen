// Three levels of nesting in one expression.
const s = "hello world";
console.log(s.substring(0, s.substring(0, s.substring(0, 5).indexOf("l")).length));
