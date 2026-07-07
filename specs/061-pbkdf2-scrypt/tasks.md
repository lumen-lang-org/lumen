# Tasks: spec 061 pbkdf2/scrypt/timingSafeEqual

- [ ] **T1 -- `crypto.pbkdf2Sync(password, salt, iterations, keylen)`.**
  De-risk first: confirm `std.crypto.pwhash.pbkdf2(dk, password, salt,
  rounds: u32, comptime Prf)` against this Zig 0.16.0 toolchain's
  `lib/std/crypto/pbkdf2.zig` (done during spec-writing; re-verify if
  anything doesn't match). Files: `src/lumen_check_stdlib.zig`
  (`cryptoCallType` gains a branch: 4 args, first two `ensureAssignable
  .buffer_type`, last two `i32`, returns `.buffer_type`, sets
  `needs_crypto_api`/`needs_buffer`), `src/lumen_emit.zig` (emit branch
  calling `__cryptoPbkdf2Sync(password, salt, iterations, keylen)`),
  `src/lumen_compiler.zig` (runtime fn in the existing
  `needs_buffer and needs_crypto_api` block, using
  `std.crypto.auth.hmac.sha2.HmacSha256` as the fixed PRF, `iterations < 1`
  or `keylen <= 0` returns an empty `Buffer`, `pwhash.pbkdf2`'s error union
  caught and folded into the same empty-`Buffer` fallback).
  Verify: 1-round vector (`password`/`salt`/32 bytes) and a 4096-round
  vector, both cross-checked against Python's `hashlib.pbkdf2_hmac`.
- [ ] **T2 -- `crypto.scryptSync(password, salt, keylen)`.** De-risk
  `std.crypto.pwhash.scrypt.kdf(allocator, derived_key, password, salt,
  Params)`'s exact signature and `Params` shape against
  `lib/std/crypto/scrypt.zig` (done during spec-writing). Same file set as
  T1. Fixed `Params{ .ln = 14, .r = 8, .p = 1 }` (Node's own scrypt
  default, N=16384/r=8/p=1 -- see spec.md's "Cost parameter choice" for why
  not Zig's `owasp` preset). `keylen <= 0` returns an empty `Buffer`; a
  `KdfError` from `kdf` folds into the same empty-`Buffer` fallback.
  Verify: determinism (same inputs -> identical output across two calls)
  and sensitivity (changing password, salt, or keylen each changes the
  output) -- no published RFC 7914 vector matches this parameter choice, so
  correctness is verified structurally rather than against a KAT.
- [ ] **T3 -- `crypto.timingSafeEqual(a, b)`.** De-risk
  `std.crypto.timing_safe.eql`/`.compare`'s exact signatures against
  `lib/std/crypto/timing_safe.zig` (done during spec-writing: `eql` needs a
  comptime-fixed-size array/vector type, not usable directly on `Buffer`'s
  runtime slice; `compare` takes runtime slices but is ordering-shaped, not
  equality-shaped -- see spec.md's "Constant-time comparison
  implementation" for the chosen alternative: a manual XOR-accumulate loop
  mirroring `eql`'s own per-element algorithm). Same file set as T1/T2,
  checker returns `.bool` (already an existing `Type` variant, used by
  `Buffer.equals`). Length mismatch returns `false` (see spec.md's
  "Length-mismatch behavior"). Verify: equal buffers -> `true`; same-length
  differing buffers -> `false`; different-length buffers -> `false`; two
  separately-constructed equal-content `Buffer.from(...)` calls compare
  equal (byte comparison, not pointer identity).
- [ ] **T4 -- docs + conformance.** Update `website/stdlib.html`'s `crypto`
  section (new short `.api-list` entries + `.api` blocks for the three
  functions, keep existing entries untouched) -- no new nav entry needed,
  `#crypto` already exists. Regression-check `sha256`/`hmacSync`/
  `encryptSync`/`decryptSync`/`createHash`/`createHmac` still work. `zig
  build test` clean. Full, clean, non-concurrent `zig build conformance`
  (206 passed / 0 failed) before committing.
