# Spec 060: streaming hash/HMAC objects (`createHash`/`createHmac`)

## Goal

Spec 057's own "Not planned" table named this exact gap:
`crypto.createHmac`/`createCipheriv` streaming/builder-style objects --
every function in this stdlib is a flat one-shot call ... a chainable
`.update()`/`.final()` builder is a different shape not otherwise used
here." This spec closes that gap for hashing, scoped down from the full
list to the two builders that matter most: `crypto.createHash(algorithm)`
and `crypto.createHmac(algorithm, key)`, both returning a stateful object
with `.update(data)` (callable 0+ times, for hashing data without holding
it all in memory at once) and `.digest()` (finalizes once, returns a
`Buffer`). Four algorithms: `md5`, `sha1`, `sha256`, `sha512`.

## Why additive, not breaking

`crypto.sha256(data): string` and `crypto.hmacSync(key, data): Buffer`
(spec 057) are untouched -- same reasoning as spec 057's own "why
additive, not breaking": both are already-shipped contracts, a hex-string
one-shot SHA-256 and a fixed-algorithm one-shot HMAC-SHA256 are still
genuinely useful shapes for the common case, and this spec adds a second,
more general shape alongside them rather than replacing either.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `crypto.createHash(algorithm)` | `string -> Hash` | `algorithm` is a runtime string: `"md5"` \| `"sha1"` \| `"sha256"` \| `"sha512"`; unrecognized falls back to `"sha256"` (see "Algorithm selection" below) |
| `crypto.createHmac(algorithm, key)` | `(string, Buffer) -> Hmac` | same four algorithms/fallback, keyed with `key`'s raw bytes |

| Method | Type | Notes |
| --- | --- | --- |
| `Hash.update(data)` | `Buffer -> Hash` | feeds `data` into the running hash; returns `self` for chaining. Callable any number of times before `.digest()` |
| `Hash.digest()` | `() -> Buffer` | finalizes the hash and returns the raw digest bytes. Calling `.update()` again after `.digest()` is undefined (matches Node: the underlying hash context is consumed) -- not defended against in v1, see "Not planned" |
| `Hmac.update(data)` | `Buffer -> Hmac` | same shape as `Hash.update` |
| `Hmac.digest()` | `() -> Buffer` | same shape as `Hash.digest`, returning the MAC bytes |

## Design notes

- **`Hash` and `Hmac` as two separate bare `Type` variants
  (`.hash_type`/`.hmac_type`), not one shared type**: mirrors the
  `ReadableStream`/`WritableStream`/`Socket`/`Buffer` precedent -- each
  distinct heap-pointer container gets its own `Type` variant, its own
  Zig struct (`LumenHash`/`LumenHmac`), and its own method dispatcher
  (`hashMethod`/`hmacMethod`) added to the same `isX`/`xMethod` dispatch
  chain in `lumen_check_expr.zig` that `isBuffer`/`isSocket` already use.
  A single shared "streaming digest" type was considered (both are
  genuinely "`.update()` 0+ times, then `.digest()` once") but rejected:
  `Hash` and `Hmac` have different constructors (`createHash(algorithm)`
  vs `createHmac(algorithm, key)`) and Node itself exposes them as
  distinct types (`crypto.Hash` vs `crypto.Hmac`) -- collapsing them into
  one Lumen type would mean either a dead unused field on `Hash` (no key)
  or a runtime-checked "was this constructed with a key" flag, neither of
  which is simpler than two small, honest types following an already-used
  mechanical pattern.
- **One Zig struct per type, dispatched internally by algorithm via a
  tagged union, not four Zig types**: `LumenHash` wraps
  `impl: HashImpl` where `HashImpl = union(enum) { md5: std.crypto.hash.Md5,
  sha1: std.crypto.hash.Sha1, sha256: std.crypto.hash.sha2.Sha256, sha512:
  std.crypto.hash.sha2.Sha512 }` (and the analogous `HmacImpl` for
  `LumenHmac`, over `std.crypto.auth.hmac.{HmacMd5,HmacSha1}`/
  `std.crypto.auth.hmac.sha2.{HmacSha256,HmacSha512}`). `update`/`digest`
  dispatch with `switch (self.impl) { inline else => |*h| ... }`, which
  lets `h.update(data)`/`h.final(&out)` resolve per-variant at comptime
  inside the switch prong (each prong's `h` has a concrete, non-erased
  type) while still being one method body, not four. This is the
  concrete Zig-level answer to the brief's "kind enum field + either a
  tagged union or four inline fields" question -- a tagged union was
  picked over four always-present inline fields because `inline else`
  gives per-variant dispatch without hand-writing the same four-armed
  switch body twice (once for `update`, once for `digest`).
- **Algorithm selection is a runtime string, unrecognized name falls back
  to `sha256`**: matches `Buffer.from(s, encoding)`'s unrecognized-encoding
  fallback (spec 056) and this codebase's "fallback, don't crash"
  convention throughout (a missing key, an out-of-range index, a wrong-
  length crypto key/iv in spec 057 -- none of these throw). `createHash`/
  `createHmac` take the algorithm as a genuine runtime string (matching
  Node's own real API -- `createHash('sha256')` is a runtime call in
  Node too, not compile-time-resolved), so there is no literal-string
  compile-time check to fall back from; the fallback is purely in the
  generated Zig's `if (eql(...)) ... else if (...) ... else` chain,
  verified concretely below with a deliberately misspelled algorithm name
  against a real compiled program.
- **`.update(data)` takes a `Buffer`, not a `string`**: every new
  capability this pass adds operates on raw bytes, the same call spec 057
  made for `hmacSync`/`encryptSync`/`decryptSync`'s data parameters (all
  `Buffer`, not `string`) -- `sha256`'s existing `string` parameter is the
  one-shot function's own already-shipped shape, not a precedent binding
  on a new, unrelated API. A caller hashing a plain string literal calls
  `Buffer.from(s)` first, one extra call, in exchange for a single
  honest byte-oriented shape across every streaming/keyed crypto
  operation in this pass and spec 057's.
- **`.update()` returns `self` (real chaining), not `void`**: confirmed
  concretely, not assumed, that returning the same heap pointer a Lumen
  instance method was called on is a trivial, already-supported shape --
  it is just a normal method whose declared return type happens to equal
  its receiver's type, no different from any other reference-returning
  method already in the checker/emitter. The checker's `hashMethod`/
  `hmacMethod` return `.hash_type`/`.hmac_type` for `update`, exactly the
  way `bufferMethod`'s `slice` already returns `.buffer_type` (a
  same-type-family return that already works); emission needs no special
  case at all, since `method_call`'s existing generic
  `mc.container_type != null` dispatch branch (used by `Buffer`/`Socket`
  methods already) just emits `obj.update(args)` verbatim -- if
  `update`'s real Zig return type is `*LumenHash`, chaining
  (`h.update(a).update(b)`) is nested `method_call` expressions that
  re-resolve through the exact same dispatch path, with no new code.
  Chaining was kept because it was genuinely free here, not forced.
- **`.digest()` returns `Buffer`, not a `string` with an encoding
  parameter**: unlike Node's `hash.digest(encoding)`, which returns text
  directly, Lumen's `Hash`/`Hmac.digest()` returns raw bytes and lets an
  already-shipped `Buffer.toString(encoding)` (spec 056) do the
  hex/base64 encoding -- this avoids a second implementation of the same
  hex/base64 logic and is strictly more capable, since the raw bytes are
  directly usable as another crypto operation's input (e.g. feeding one
  hash's digest into another as `Buffer`) without an encode/decode
  round-trip Node's string-only `digest(encoding)` would force. Verified
  concretely below (`.digest().toString("hex")` and `.toString("base64")`
  both round-trip correctly).
- **No defense against calling `.update()` after `.digest()`**: Node's
  own `Hash`/`Hmac` throw `ERR_CRYPTO_HASH_FINALIZED` if you do this;
  Zig's underlying hash/HMAC context has no such guard (`.final()` just
  reads out the current state, it doesn't invalidate the struct), so
  calling `.update()` after `.digest()` in this implementation silently
  keeps hashing into the same live context rather than either
  continuing correctly or crashing. Documented as a real, deliberate gap
  (matching "fallback/don't crash" in spirit, though this one is closer to
  "undefined but not unsafe") rather than adding a `finalized: bool` guard
  field and a new failure mode this pass didn't need to invent.

## Verification

A real `.ts` program, compiled and run through `zig-out/bin/lumen`:
- MD5(""), SHA-1("abc"), SHA-256("abc"), SHA-512("abc") each computed via
  `createHash(algo).update(Buffer.from(...)).digest().toString("hex")`
  and compared against the same algorithm's `*sum` shell command output
  (not transcribed from memory -- computed and cross-checked during
  spec-writing).
- Incremental accumulation is real: `createHash("sha256").update(Buffer.
  from("ab")).update(Buffer.from("c")).digest()` equals the one-shot
  digest of `"abc"`, proving `.update()` genuinely accumulates state
  across calls rather than only remembering the last call's argument.
- `createHmac` cross-checked against the existing one-shot `hmacSync`:
  `createHmac("sha256", Buffer.from("key")).update(Buffer.from("The quick
  brown fox jumps over the lazy dog")).digest()` produces the identical
  32 bytes as `crypto.hmacSync(Buffer.from("key"), Buffer.from(...))`
  (`f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8`).
- An unrecognized algorithm name (e.g. `"sha3"`) falls back to sha256,
  confirmed by checking the digest length/value against a known
  sha256 vector, not just reading the checker code.
- `.digest().toString("hex")` and `.toString("base64")` both verified
  against known-correct values.
- Regression: `crypto.sha256()` and `crypto.hmacSync()` still produce
  their spec-057 values unchanged.

## Not planned (this pass)

| Group | Needs |
| --- | --- |
| `crypto.createCipheriv`/streaming AEAD | a stateful encrypt/decrypt object is a real, separate shape (associated-data ordering, partial-block buffering) from a pure hash accumulator; not attempted here |
| Guarding against `.update()` after `.digest()` | Node throws; this implementation silently keeps accumulating into the already-finalized context -- a real, documented gap, not a crash risk, deferred until there's a concrete need |
| `.digest(encoding)` returning a `string` directly | rejected in favor of `Buffer` + the already-shipped `.toString(encoding)`, see design notes |
| Algorithms beyond md5/sha1/sha256/sha512 (sha224/sha384/blake2/blake3/etc.) | `std.crypto.hash`/`std.crypto.auth.hmac` has more than these four; a real, separable expansion once there's a concrete need, matching spec 057's own deferral of the same point for `hmacSync` |
| `.update(data: string)` overload | every new byte-oriented crypto API this pass and spec 057 add takes `Buffer`, not `string`; adding a second overload is a real, separate ergonomics decision, not bundled here |
