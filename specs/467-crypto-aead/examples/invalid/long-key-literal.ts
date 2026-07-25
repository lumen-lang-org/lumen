// Too long is rejected for the same reason as too short: silently dropping the
// tail would decrypt under a key the caller did not write.
console.log(crypto.decrypt("QUJD", "0123456789abcdef0123456789abcdef!"));
