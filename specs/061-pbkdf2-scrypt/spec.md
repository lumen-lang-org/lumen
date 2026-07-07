# Spec 061: password-based key derivation and constant-time compare

## Goal

Spec 057/060 covered one-shot and streaming digests/MACs and one authenticated
cipher. The remaining, near-universal gap in real auth code is password-based
key derivation (turning a low-entropy password into a fixed-length key,
suitable for storage or as a symmetric key) and constant-time comparison of
secrets (so a MAC/token check doesn't leak timing information about where two
byte strings first differ). This spec adds three functions to the same
`crypto` namespace: `pbkdf2Sync`, `scryptSync`, `timingSafeEqual`. All three
are `Buffer` in/out or `Buffer` in, `bool` out -- no new heap-pointer `Type`
variant is needed, unlike spec 060's `Hash`/`Hmac`.

## Why additive, not breaking

Pure additions to `crypto`; nothing existing changes shape or behavior.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `crypto.pbkdf2Sync(password, salt, iterations, keylen)` | `(Buffer, Buffer, int, int) -> Buffer` | PBKDF2-HMAC-SHA256 (`std.crypto.pwhash.pbkdf2` with `std.crypto.auth.hmac.sha2.HmacSha256`, the same PRF `hmacSync` already uses). Fixed PRF, no algorithm parameter -- see "One PRF" below. `iterations < 1` or `keylen <= 0` returns an empty `Buffer` |
| `crypto.scryptSync(password, salt, keylen)` | `(Buffer, Buffer, int) -> Buffer` | scrypt (`std.crypto.pwhash.scrypt.kdf`) with fixed cost parameters `N=16384 (ln=14), r=8, p=1` -- see "Cost parameter choice" below. `keylen <= 0` returns an empty `Buffer` |
| `crypto.timingSafeEqual(a, b)` | `(Buffer, Buffer) -> bool` | constant-time byte comparison. Different-length inputs return `false` immediately (not constant-time across the length check itself, but lengths aren't secret -- see "Length-mismatch behavior" below) |

## Design notes

- **`password`/`salt` as `Buffer`, not `string`**: matches spec 057/060's own
  established call -- every byte-oriented crypto input added since spec 057
  (`hmacSync`, `encryptSync`/`decryptSync`, `Hash.update`/`Hmac.update`) takes
  `Buffer`, never `string`. Passwords and salts are arbitrary byte data (a
  salt in particular is conventionally random bytes, not text), so there is
  no honest string-only shape here either. A caller with a string password
  calls `Buffer.from(s)` first, the same one extra call spec 060 already
  asks callers to make.
- **One PRF for `pbkdf2Sync`, no algorithm parameter**: matches
  `hmacSync`/`sha256`'s existing one-algorithm precedent and this stdlib's
  repeated "one well-chosen option, not the whole matrix" convention (zlib:
  one format; `Buffer`: three encodings; `hmacSync`: one algorithm).
  HMAC-SHA256 is Node's own most common PBKDF2 digest choice today (Node's
  legacy default was SHA-1; SHA-256 is the modern recommended choice and the
  one this codebase already ships via `hmacSync`, so reusing it here needs no
  new primitive). A `pbkdf2Sync(password, salt, iterations, keylen, digest)`
  overload is a real, separable future expansion, not attempted here.
- **Cost parameter choice for `scryptSync`: Node's own default
  (`N=16384`/`ln=14`, `r=8`, `p=1`), not Zig's `owasp` preset**: Zig's
  `std.crypto.pwhash.scrypt.Params` ships `interactive`
  (`fromLimits(524288, 16777216)`, effectively a large N) and `owasp`
  (`ln=17`, i.e. `N=131072`) but neither matches Node's `crypto.scrypt`'s own
  documented default of `N=16384, r=8, p=1`. Both are defensible; this spec
  picks Node's default specifically because (a) it's the parameter set the
  overwhelming majority of real-world Node callers actually run today (most
  never override `crypto.scrypt`'s defaults), so Lumen code migrating from or
  interoperating with Node-derived expectations sees familiar cost/latency,
  and (b) it keeps `scryptSync` fast enough to run repeatedly in this
  project's own conformance suite (`N=16384, r=8` needs a working-memory
  buffer of `32 * N * r * 4` bytes = 16 MiB and completes in well under a
  second; `owasp`'s `N=131072` needs 128 MiB and is noticeably slower per
  call) without the cost parameters being exposed as a v1 parameter to trade
  that off per-call. This is a deliberate, stated deviation from Zig's own
  named "recommended" preset, not an oversight -- documented here per this
  codebase's convention of stating divergences rather than silently picking
  one. A `scryptSync(password, salt, keylen, options)` overload exposing
  `N`/`r`/`p` (or Zig's presets by name) is a real, separable future
  expansion.
- **`timingSafeEqual`'s length-mismatch behavior: return `false`, don't
  throw**: Node's real `crypto.timingSafeEqual` throws
  `ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH` (a `TypeError`) on a length mismatch.
  Lumen's stdlib static calls have no throw/catch target to begin with --
  confirmed by reading `lumen_check_stdlib.zig`'s own `assertCallType`
  comment, which states a static call has no access to an enclosing `try`'s
  throw target, which is why even `assert.ok` crashes the whole program
  (uncatchable) rather than throwing a catchable error. Every fallible
  crypto builtin shipped so far (`encryptSync`/`decryptSync`'s wrong-length
  key/iv in spec 057, `Buffer.from`'s unrecognized encoding in spec 056)
  returns a safe default instead of crashing or throwing, and a
  length-mismatch here is exactly that shape: `a.length`/`b.length` are
  already public, non-secret values the caller wrote in their own code (this
  function only protects the *byte comparison*, not the lengths), so
  returning `false` immediately leaks nothing beyond what the caller already
  knew, and is cryptographically sound as a "not equal" answer (mismatched
  lengths are never equal). Matching Node's throw would need a new
  language-level capability (stdlib static calls that can throw) that
  doesn't exist yet and is out of scope for this spec.
- **Constant-time comparison implementation: a manual XOR-accumulate loop
  over the two runtime-length `[]const u8` slices, not
  `std.crypto.timing_safe.eql` or `.compare`**: `timing_safe.eql(comptime T,
  a: T, b: T)` requires `T` to be a fixed-size array or vector type (checked
  via `@typeInfo(T) == .array` internally) -- confirmed by reading
  `lib/std/crypto/timing_safe.zig` directly. `Buffer`'s `.data` is a runtime
  `[]const u8` of caller-determined length, so `eql` cannot be called
  directly without a `comptime`-known length, which the two buffers being
  compared do not have. `timing_safe.compare(comptime T, a: []const T, b:
  []const T, endian: Endian) Order` does accept runtime-length slices and,
  read in full, its inner loop is genuinely constant-time for a given
  length (it iterates every element unconditionally, accumulating `gt`/`eq`
  bitwise with no early exit or per-element branch); it was a real
  candidate. It was not used here because (a) its final `if (gt != 0) ...
  else if (eq != 0) ...` branch and its big/little-endian multi-precision
  integer semantics are designed for numeric ordering, not byte-string
  equality, and reusing it for equality means computing and discarding an
  `Order` that isn't the natural output shape; (b) `timing_safe.eql`'s own
  algorithm -- `acc |= x ^ b[i]` over every element, then one final
  branchless-in-`eql`'s case bit-trick derivation of the boolean -- is the
  simpler, more directly-fit-for-purpose algorithm, and is also exactly the
  same technique used by industry-standard constant-time comparisons
  (OpenSSL's `CRYPTO_memcmp`, libsodium's `sodium_memcmp`): XOR-accumulate
  every byte with no early exit, then a single comparison of the
  accumulator against zero at the very end. This implementation mirrors
  `eql`'s per-element accumulation exactly, just written over a runtime
  length instead of a `comptime`-known array size, then does `acc == 0`
  (one final branch, encoding only the already-to-be-returned answer, the
  same shape `eql`'s own bit-trick and `compare`'s final branch both have --
  neither hides the *result*, only the *position* of any difference, which
  is the actual property being protected). The length check happens before
  the loop and short-circuits on mismatch (see previous note for why that's
  fine).

## Verification

A real `.ts` program, compiled and run through `zig-out/bin/lumen`:
- `pbkdf2Sync(Buffer.from("password"), Buffer.from("salt"), 1, 32)` matches
  the independently-computed Python
  `hashlib.pbkdf2_hmac("sha256", b"password", b"salt", 1, 32).hex()` ->
  `120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b`.
- A higher round count changes the output and still matches Python:
  `pbkdf2Sync(Buffer.from("password"), Buffer.from("salt"), 4096, 20)` ->
  `c5e478d59288c841aa530db6845c4c8d962893a0` (matches
  `hashlib.pbkdf2_hmac("sha256", b"password", b"salt", 4096, 20).hex()`),
  confirming rounds and keylen both take effect, not just a fixed-shape stub.
- `scryptSync`: same password/salt/keylen produces identical output across
  two calls (determinism); changing password, salt, or keylen each changes
  the output (not a no-op or constant stub).
- `timingSafeEqual`: equal buffers -> `true`; same-length differing buffers
  -> `false`; different-length buffers -> `false` (documented fallback, not
  a crash); two separately-constructed `Buffer.from("secret")` calls (
  different underlying allocations, same bytes) compare equal, proving
  byte comparison rather than pointer identity.
- Regression: `crypto.sha256`, `hmacSync`, `encryptSync`/`decryptSync`,
  `createHash`/`createHmac` all still produce their existing values
  unchanged.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| `pbkdf2Sync(..., digest)` algorithm-name parameter | `std.crypto.auth.hmac` has more PRFs; a real, separable expansion once there's a concrete need, matching spec 057/060's own deferral of the same point |
| `scryptSync(..., options)` exposing `N`/`r`/`p` | fixed default chosen deliberately for v1 (see "Cost parameter choice"); exposing tunable cost is a real, separate API surface decision |
| Matching Node's exact throw-on-length-mismatch behavior for `timingSafeEqual` | needs stdlib static calls to support throwing a catchable Lumen error, a capability that doesn't exist yet for any builtin in this codebase |
| `crypto.scrypt`/`pbkdf2` async (non-`Sync`) variants | every crypto function shipped so far is synchronous/one-shot; an async KDF is a different shape not otherwise used here |
