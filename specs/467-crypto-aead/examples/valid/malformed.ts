// Anything that is not an envelope this key produced returns the empty string,
// without crashing and without saying which check rejected it.
const key = "0123456789abcdef0123456789abcdef";
const envelope = crypto.encrypt("sk-fake-openai-00000", key);

// Truncated: still valid base64, but the plaintext bytes and part of the tag
// are gone.
console.log(crypto.decrypt(envelope.substring(0, 16), key) === "");

// Long enough to be an envelope, but the trailing bytes were cut off mid-tag.
console.log(crypto.decrypt(envelope.substring(0, envelope.length - 4), key) === "");

// Nothing at all.
console.log(crypto.decrypt("", key) === "");

// Not base64.
console.log(crypto.decrypt("not base64 at all!!", key) === "");

// Base64-shaped but far too short to hold a 12-byte nonce and a 16-byte tag.
console.log(crypto.decrypt("QUJD", key) === "");
