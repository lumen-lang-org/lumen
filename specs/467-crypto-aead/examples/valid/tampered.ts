// Authentication: an envelope that anyone altered, and an envelope opened with
// the wrong key, both fail. This is the property a plain cipher does not have
// -- without the tag, a flipped byte would decrypt to a different plaintext and
// the caller would have no way to tell.
const key = "0123456789abcdef0123456789abcdef";
const other = "fedcba9876543210fedcba9876543210";
const secret = "sk-fake-anthropic-000";

const envelope = crypto.encrypt(secret, key);

// Wrong key.
console.log(crypto.decrypt(envelope, other) === "");

// One character of the envelope changed. Index 20 sits past the encoded nonce,
// inside the ciphertext, and the replacement is chosen to differ from whatever
// is already there so the envelope is genuinely modified.
const at = envelope.substring(20, 21);
const alt = at === "A" ? "B" : "A";
const flipped = envelope.substring(0, 20) + alt + envelope.substring(21, envelope.length);
console.log(flipped !== envelope);
console.log(crypto.decrypt(flipped, key) === "");

// The unmodified envelope still opens, so the two checks above failed because
// of the tampering and not because decrypt rejects everything.
console.log(crypto.decrypt(envelope, key) === secret);
