// fs in Lumen's shapes: string results, mkdirSync(path, recursive),
// statSync as a record, readSync(fd, n), streams with readLine.
let dir: string = fs.mkdtempSync(os.tmpdir() + "/lumen-503-");
fs.mkdirSync(dir + "/a/b/c", true);
fs.mkdirSync(dir + "/a");
fs.writeFileSync(dir + "/a/f.txt", "one\n\ntwo");
fs.appendFileSync(dir + "/a/f.txt", "!");
console.log(fs.readFileSync(dir + "/a/f.txt", "utf8"));
let st = fs.statSync(dir + "/a/f.txt");
console.log(st.size, st.isFile, st.isDirectory);
let missing = fs.statSync(dir + "/nope");
console.log(missing.size, missing.isFile, missing.isDirectory, missing.mtimeMs);
console.log(fs.existsSync(dir + "/a"), fs.existsSync(dir + "/zzz"), fs.accessSync(dir + "/zzz"));
let fd: int = fs.openSync(dir + "/a/f.txt", "r");
console.log(fs.readSync(fd, 3));
console.log(fs.readSync(fd, 100).length);
console.log(fs.readSync(fd, 100).length);
fs.closeSync(fd);
console.log(fs.openSync(dir + "/no/such", "r"));
let s = fs.createReadStream(dir + "/a/f.txt");
let line: string = s.readLine();
let n: int = 0;
while (line != "") {
  n = n + 1;
  console.log(n, line.length);
  line = s.readLine();
}
s.close();
console.log(fs.readdirSync(dir + "/a").length, fs.readdirSync(dir + "/none").length);
console.log(fs.readlinkSync(dir + "/a/f.txt") == "");
try {
  fs.readFileSync(dir + "/absent.txt");
} catch (e) {
  console.log("threw");
}
fs.rmSync(dir, true);
console.log(fs.existsSync(dir));
