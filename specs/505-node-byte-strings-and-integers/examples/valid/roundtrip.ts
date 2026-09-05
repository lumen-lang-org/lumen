// FR-004: text crosses the runtime boundary as bytes in both directions. A
// UTF-8 file written, read back, ASCII-uppercased and written again holds
// the same bytes natively and under Node.
const file = path.join(os.tmpdir(), "lumen-505-roundtrip-" + String(process.pid()) + ".txt");
const original = "héllo wörld — ça va?";
fs.writeFileSync(file, original);
const read = fs.readFileSync(file, "utf8");
console.log(read.length);
console.log(read == original);
fs.writeFileSync(file, read.toUpperCase());
const back = fs.readFileSync(file, "utf8");
console.log(back.length);
console.log(back);
console.log(back.charCodeAt(1), back.charCodeAt(2), back.indexOf("ç"));
fs.rmSync(file);
console.log(fs.existsSync(file));
