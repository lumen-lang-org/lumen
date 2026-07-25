// Every string method that opens a block, called on a receiver that is itself
// such a call, so the two blocks nest.
const s = "  Hello, World!  ";
const t = s.trim();
console.log(s.trim().toUpperCase());
console.log(s.trim().toLowerCase());
console.log(s.trim().trimStart().trimEnd());
console.log(s.trim().charAt(t.indexOf("W")));
console.log(s.trim().at(t.indexOf("W")) ?? "?");
console.log(s.trim().charCodeAt(t.indexOf("W")));
console.log(s.trim().codePointAt(t.indexOf("W")));
console.log(s.trim().indexOf(t.substring(0, 1)));
console.log(s.trim().lastIndexOf(t.substring(1, 2)));
console.log(s.trim().localeCompare(t.substring(0, t.length)));
console.log(s.trim().includes(t.substring(7, 12)));
console.log(s.trim().startsWith(t.substring(0, 5)));
console.log(s.trim().endsWith(t.substring(t.length - 1, t.length)));
console.log(s.trim().slice(0, t.slice(0, 5).length));
console.log(s.trim().substring(0, t.substring(0, 5).length));
console.log(s.trim().concat(t.substring(0, 1)));
console.log(s.trim().repeat(t.substring(0, 2).length));
console.log(s.trim().padStart(t.substring(0, 3).length + 15, "."));
console.log(s.trim().padEnd(t.substring(0, 3).length + 15, "."));
console.log(s.trim().replace("l", t.substring(0, 1)));
console.log(s.trim().replaceAll("l", t.substring(0, 1)));
console.log(s.trim().split(t.substring(5, 6)).length);
