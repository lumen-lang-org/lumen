# Spec 057: crypto cashes in on Buffer -- HMAC, AES-256-GCM, raw randomBytes

## Goal

Spec 056 shipped `Buffer` and explicitly deferred wiring it into `crypto`,
calling it "a real, separate follow-up migration" in its Not-planned table.
This spec is that follow-up, scoped to the capabilities `Buffer` newly makes
possible: authenticated encryption and message authentication codes, both of
which operate on raw bytes and have no honest string-only shape. It does
**not** touch the three existing `crypto` functions' return types -- see
"Why additive, not breaking" below.

## Why additive, not breaking

`crypto.randomBytes`/`randomUUID`/`sha256` already ship and are exercised
(conformance + examples) as hex-`string`-returning. Changing their return
type to `Buffer` would be a breaking change to an already-shipped contract
for a benefit that doesn't clearly outweigh the cost: a hex digest is
genuinely useful as text (comparison, display, storage as a column), and
every caller today gets that for free. Node itself keeps this duality
(`Buffer` under the hood, `.toString('hex')` for text) rather than forcing
one shape. Lumen's version of that duality is simpler: keep the three
existing functions as-is, and add a fourth, `crypto.randomBytesBuffer(n)`,
for callers who want raw bytes without a name that implies a return-type
change on an existing function. HMAC and AES-GCM are **new** capabilities
with no existing string-returning contract to preserve, so they're `Buffer`
in and `Buffer` out from the start -- there's no honest hex-string shape for
ciphertext or a MAC that wouldn't just be `.toString("hex")` bolted on
after the fact, which callers can already do themselves via `Buffer`.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `crypto.randomBytesBuffer(n)` | `int -> Buffer` | `n` cryptographically random bytes, no hex encoding. Same entropy source as `randomBytes` (`std.Io.random`), a negative `n` clamps to 0 |
| `crypto.hmacSync(key, data)` | `(Buffer, Buffer) -> Buffer` | HMAC-SHA256 (`std.crypto.auth.hmac.sha2.HmacSha256`), a 32-byte MAC. Fixed algorithm, no algorithm-name parameter -- see "One algorithm" below |
| `crypto.encryptSync(key, iv, data)` | `(Buffer, Buffer, Buffer) -> Buffer` | AES-256-GCM authenticated encryption (`std.crypto.aead.aes_gcm.Aes256Gcm`). `key` must be 32 bytes, `iv` must be 12 bytes (GCM's standard nonce length) -- a wrong-length key/iv returns an empty `Buffer` rather than crashing. Output is `ciphertext \|\| 16-byte tag` concatenated into one `Buffer` (see "Tag placement" below); no associated data (AAD) parameter in v1 |
| `crypto.decryptSync(key, iv, data)` | `(Buffer, Buffer, Buffer) -> Buffer` | inverse of `encryptSync`; splits the trailing 16 bytes off `data` as the tag before verifying. Returns an empty `Buffer` on a wrong-length key/iv, a too-short `data` (< 16 bytes), *or* a failed authentication check (tampered ciphertext/tag) -- the same fallback-don't-crash shape every other fallible builtin here uses |

## Design notes

- **One algorithm, not a name parameter**: matches `crypto.sha256`'s own
  existing precedent (no algorithm parameter there either) and the
  `zlib`/`Buffer` modules' "one well-chosen option, not the whole matrix"
  convention. HMAC-SHA256 and AES-256-GCM are the standard "just give me
  the good default" picks in every mainstream crypto library. A
  `hmacSync(algorithm, key, data)` overload family is a real, separable
  future expansion (`std.crypto.auth.hmac` already has MD5/SHA1/SHA224/
  SHA384/SHA512 built in), not attempted here.
- **AES-256-GCM over AES-CBC**: GCM is authenticated encryption (tamper
  produces a hard decrypt failure, not silently-wrong plaintext); CBC
  without a separate MAC is a well-known footgun. Given this pass adds
  exactly one cipher, the authenticated one is the only defensible default.
- **Tag placement (`ciphertext \|\| tag`, not a separate return value)**:
  Lumen's static-call return type is a single `Type`; there's no ergonomic
  two-value return here without inventing a tuple-returning static call (an
  untested combination -- tuple types exist in the language but every
  static call in the stdlib today returns exactly one value). Concatenating
  the 16-byte tag onto the ciphertext is the simplest single-value shape
  that's still trivially decomposable (verified: `decryptSync` re-splits it
  internally, verified round-trip below) and is the same "just append it"
  shape `Buffer`'s own design notes chose over inventing new plumbing where
  a single-value shape already covers the case.
- **Fixed-length array conversion**: `Aes256Gcm.encrypt`/`decrypt` and
  `HmacSha256.create` take fixed-size arrays (`[32]u8`, `[12]u8`) by value,
  not slices -- confirmed by reading `lib/std/crypto/aes_gcm.zig` and
  `hmac.zig` directly in this exact Zig 0.16.0 toolchain before writing any
  compiler code, since a slice-vs-fixed-array mismatch here would be a
  compile error in the *generated* Zig, one layer removed from Lumen's own
  diagnostics. `key.data`/`iv.data` (runtime-length `[]const u8`) are
  length-checked, then `@memcpy`'d into a stack-local fixed array before the
  call.
- **`crypto.randomBytesBuffer` reuses the same entropy call
  (`std.Io.random(io, buf)`) as the existing `randomBytes`** -- verified by
  reading the current `__cryptoRandomBytes` implementation rather than
  guessing at the random API shape.

## Verification

A real `.ts` program, compiled and run through `zig-out/bin/lumen`:
- `hmacSync` against the known HMAC-SHA256 test vector from
  `lib/std/crypto/hmac.zig`'s own test block (key `"key"`, message
  `"The quick brown fox jumps over the lazy dog"` ->
  `f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8`),
  via `.toString("hex")` on the returned `Buffer`.
- `encryptSync`/`decryptSync` round-trip: encrypt a message, decrypt the
  result, confirm the recovered plaintext equals the original via
  `Buffer.equals`.
- Tamper detection: flip a byte in the ciphertext (via `Buffer.slice` +
  reassembly, or by encrypting then corrupting one byte of the raw output)
  and confirm `decryptSync` returns an empty `Buffer` (`.length == 0`)
  instead of wrong plaintext or a crash.
- Wrong-length key/iv both return an empty `Buffer` rather than crashing.
- `randomBytesBuffer(n).length == n` for a few `n`, and two consecutive
  calls differ (real entropy, not a fixed pattern).

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| Changing `randomBytes`/`randomUUID`/`sha256`'s return type | breaking change to an already-shipped contract; see "Why additive, not breaking" |
| Algorithm-name parameter for `hmacSync` (sha1/sha512/etc.) | `std.crypto.auth.hmac` already has the primitives; a real, separable expansion once there's a concrete need |
| AES-CBC, AES-CTR, or unauthenticated modes | GCM's authentication is the safer default; exposing footgun-prone modes needs a real reason, not "Node has them" |
| Associated data (AAD) parameter on `encryptSync`/`decryptSync` | GCM supports it, but it's a real API surface decision (empty-string default vs a third optional param) deferred until a concrete use case exists |
| `crypto.createHmac`/`createCipheriv` streaming/builder-style objects | every function in this stdlib is a flat one-shot call (`sha256(s)`, `gzipSync(s)`); a chainable `.update()`/`.final()` builder is a different shape not otherwise used here |
