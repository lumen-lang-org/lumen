// compile-run: a two-exchange conversation with a persistent `cat` child, then
// a clean close. Each readLine keeps its trailing newline, so the printed line
// contains the two echoed values with their newlines inside the brackets.
let empty: string[] = [];
let cp = child_process.spawn("cat", empty);
cp.writeLine("ping");
let a = cp.readLine();
cp.writeLine("pong");
let b = cp.readLine();
cp.close();
console.log(`[${a}][${b}]`);
