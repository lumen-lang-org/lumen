// R2: a string out-parameter, beside a returned status.
function readInto(path: string, text: Ref<string>): bool {
  if (!fs.existsSync(path)) { return false; }
  text = "read: " + path;
  return true;
}
let body: string = "";
if (readInto("/etc/hostname", body)) { console.log(body); }
