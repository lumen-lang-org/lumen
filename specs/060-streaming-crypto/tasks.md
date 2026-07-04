# Tasks: spec 060 streaming hash/HMAC objects

- [ ] **T1 -- `Type` variants.** `src/lumen_types.zig`: add `.hash_type`
  and `.hmac_type` (bare, no payload, like `.buffer_type`/`.socket_type`)
  to the `Type` union; follow every exhaustive-switch compile error to
  `mangle` ("hash"/"hmac"), `same`, `toAnnotation` ("Hash"/"Hmac"),
  `zigName` ("*LumenHash"/"*LumenHmac"); add `isHash`/`isHmac` helpers
  mirroring `isBuffer`/`isSocket`. `src/lumen_check.zig`'s
  `typeFromAnnotation`: add `"Hash"`/`"Hmac"` cases right after the
  existing `"Buffer"` case, same shape.
- [ ] **T2 -- checker: `createHash`/`createHmac` static calls.**
  `src/lumen_check_stdlib.zig`'s `cryptoCallType` gains two branches:
  `createHash` (1 string arg -> `.hash_type`, sets `program.needs_buffer`
  and a new `program.needs_streaming_crypto` flag in
  `src/lumen_ast.zig`), `createHmac` (string arg + `Buffer`-assignable
  arg -> `.hmac_type`, same flags).
- [ ] **T3 -- checker: `hashMethod`/`hmacMethod`.** New functions in
  `lumen_check_stdlib.zig` mirroring `bufferMethod`'s shape exactly
  (`mc.container_type = obj_type;` then dispatch by `mc.name`): `update`
  (1 arg, `Buffer`-assignable, returns the same container type for
  chaining) and `digest` (0 args, returns `.buffer_type`, sets
  `program.needs_buffer`). Wire both into `lumen_check_expr.zig`'s
  method-call dispatch chain right after `types.isBuffer(obj_type)`.
- [ ] **T4 -- emit: `createHash`/`createHmac` static-call emission.**
  `src/lumen_emit.zig`'s `static_call` branch chain gains two entries
  (`crypto.createHash` -> `__cryptoCreateHash(<algo>)`,
  `crypto.createHmac` -> `__cryptoCreateHmac(<algo>, <key>)`). No new
  code needed for `.update`/`.digest()` emission -- the existing generic
  `mc.container_type != null` branch (already used by `Buffer`/`Socket`
  methods) emits `obj.update(args)`/`obj.digest()` verbatim as long as
  T3 sets `mc.container_type`.
- [ ] **T5 -- runtime: `LumenHash`/`LumenHmac`.** De-risk first: read
  `lib/std/crypto/md5.zig`, `Sha1.zig` (capital S), `sha2.zig`,
  `hmac.zig` in this exact vendored Zig 0.16.0 toolchain and confirm
  `init`/`update`/`final`/`digest_length` (hash) and
  `init`/`update`/`final`/`mac_length` (hmac) signatures match this
  brief before writing the verbatim Zig block, since a prior agent this
  session found subtle mismatches elsewhere. `src/lumen_compiler.zig`:
  a new `if (program.needs_streaming_crypto)` block (after the existing
  `needs_buffer`/`needs_crypto_api` blocks, since it references
  `LumenBuffer`) defining `HashImpl`/`LumenHash`/`HmacImpl`/`LumenHmac`
  (tagged unions, `switch (self.impl) { inline else => |*h| ... }` for
  `update`/`digest`) plus `__cryptoCreateHash(algorithm)`/
  `__cryptoCreateHmac(algorithm, key)` constructors with the
  fallback-to-sha256 `if/else if/.../else` chain on the algorithm string.
- [ ] **T6 -- verification program + regression + docs.** A real `.ts`
  program (entry function NOT named `main`) covering every item in
  spec.md's Verification section: MD5(""), SHA-1/256/512("abc") via
  `createHash`, incremental `update("ab")+update("c")` == one-shot
  `"abc"` for sha256, `createHmac` matching the existing `hmacSync` for
  the spec-057 vector, an unrecognized algorithm name falling back to
  sha256, `.digest().toString("hex"/"base64")` both correct, and a
  regression check that `crypto.sha256`/`hmacSync` are unchanged. Update
  `website/stdlib.html`'s `#crypto` section: new `.api-list` entries +
  `.api` blocks for `createHash`/`Hash.update`/`Hash.digest`/
  `createHmac`/`Hmac.update`/`Hmac.digest`; remove/update the two
  now-stale "Not planned" table rows (`crypto.createHash(algo) streaming
  API` and `crypto.createHmac()` in the `<h4>crypto</h4>` deferred-work
  table) since this pass ships both. Validate stdlib.html tag balance
  with the existing `python3`/`html.parser` check. `zig build test`
  clean; one full, clean, non-concurrent `zig build conformance` (206
  passed / 0 failed).
