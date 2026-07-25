// A literal key of the wrong length is settled while compiling: padding or
// truncating it would encrypt under a key nobody chose.
const envelope = crypto.encrypt("sk-fake-0000", "too short");
console.log(envelope.length);
