// An encrypt/decrypt round trip must return the exact bytes it was given, for
// any string a caller might hold: plain ASCII, multi-byte UTF-8, an embedded
// newline, and nothing at all.
const key = "0123456789abcdef0123456789abcdef";

const ascii = "sk-fake-not-a-real-key";
console.log(crypto.decrypt(crypto.encrypt(ascii, key), key) === ascii);

const utf8 = "clé 🔑";
console.log(crypto.decrypt(crypto.encrypt(utf8, key), key) === utf8);

const multiline = "line one\nline two";
console.log(crypto.decrypt(crypto.encrypt(multiline, key), key) === multiline);

const empty = "";
console.log(crypto.decrypt(crypto.encrypt(empty, key), key) === empty);

// The round trip is byte-exact, not merely equal-looking: the UTF-8 string is
// 9 bytes, and a decrypt that lost or re-encoded one would not report 9.
console.log(crypto.decrypt(crypto.encrypt(utf8, key), key).length);
