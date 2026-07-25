// crypto.randomKey() exists so a caller never has to invent a master key by
// hand: it returns exactly the 32 bytes encrypt and decrypt require, from the
// same entropy source randomBytes uses.
const k1 = crypto.randomKey();
const k2 = crypto.randomKey();

console.log(k1.length);
console.log(k2.length);
console.log(k1 !== k2);

const secret = "sk-fake-provider-0000";
console.log(crypto.decrypt(crypto.encrypt(secret, k1), k1) === secret);

// A key from one call does not open an envelope sealed with another.
console.log(crypto.decrypt(crypto.encrypt(secret, k1), k2) === "");
