# Tasks: spec 057 crypto + Buffer

- [ ] **T1 -- `crypto.randomBytesBuffer(n)`.** Files:
  `src/lumen_check_stdlib.zig` (`cryptoCallType` gains a branch, returns
  `.buffer_type`), `src/lumen_emit.zig` (emit branch calling a new
  `__cryptoRandomBytesBuffer(__io, n)`), `src/lumen_compiler.zig` (runtime
  fn inside the existing `needs_crypto_api` block, reusing
  `std.Io.random(io, buf)` verbatim and wrapping via `LumenBuffer.__wrap`
  -- requires `needs_buffer` to also be set when this path is used).
  Verify: `.length == n` for a few `n`, two calls differ, `n < 0` clamps
  to an empty `Buffer`.
- [ ] **T2 -- `crypto.hmacSync(key, data)`.** De-risk first: confirm
  `std.crypto.auth.hmac.sha2.HmacSha256.create(out, msg, key)`'s exact
  signature against this Zig 0.16.0 toolchain's `lib/std/crypto/hmac.zig`
  (done during spec-writing; re-verify if anything doesn't match). Same
  file set as T1 plus the runtime fn takes two `*LumenBuffer` args and
  reads `.data` directly. Verify against the known test vector in
  `hmac.zig`'s own test block (key `"key"`, message `"The quick brown fox
  jumps over the lazy dog"` -> digest
  `f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8`).
- [ ] **T3 -- `crypto.encryptSync`/`decryptSync` (AES-256-GCM).** De-risk
  `std.crypto.aead.aes_gcm.Aes256Gcm`'s exact fixed-array signatures
  against `lib/std/crypto/aes_gcm.zig` (done during spec-writing). Wrong-
  length key (!= 32 bytes) or iv (!= 12 bytes) returns an empty `Buffer`
  from both directions. `encryptSync` output is `ciphertext || 16-byte
  tag` in one `Buffer`; `decryptSync` re-splits it and returns an empty
  `Buffer` on a failed `AuthenticationError`. Verify: real round-trip
  (encrypt then decrypt recovers the original via `Buffer.equals`), a
  single flipped ciphertext byte causes `decryptSync` to return an empty
  `Buffer` (not wrong plaintext, not a crash), and both wrong-length paths.
- [ ] **T4 -- docs + conformance.** Update `website/stdlib.html`'s
  `crypto` section (new `.api` blocks for the three functions, keep the
  existing three untouched) -- no new nav entry needed, `#crypto` already
  exists. `zig build test` clean. Full, clean, non-concurrent `zig build
  conformance` (206 passed / 0 failed) before committing.
