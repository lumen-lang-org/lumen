// The same plaintext encrypted twice under the same key must produce two
// different envelopes. A nonce that was fixed, or derived from the plaintext,
// would produce identical ones -- and identical envelopes under one key are
// what breaks GCM, so this is the property worth asserting directly.
const key = "0123456789abcdef0123456789abcdef";
const secret = "sk-fake-mistral-0000";

const a = crypto.encrypt(secret, key);
const b = crypto.encrypt(secret, key);
const c = crypto.encrypt(secret, key);

console.log(a !== b);
console.log(b !== c);
console.log(a !== c);

// Different envelopes, same plaintext back out of each.
console.log(crypto.decrypt(a, key) === secret);
console.log(crypto.decrypt(b, key) === secret);
console.log(crypto.decrypt(c, key) === secret);
