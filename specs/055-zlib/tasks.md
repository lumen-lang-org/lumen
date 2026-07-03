# Tasks: zlib (gzip/deflate compression)

## Phase 0: de-risk (before any compiler code)

- [x] T0 Standalone Zig program against this toolchain's actual
  `std.compress.flate` API (not memory/prior-version assumptions): one-shot
  compress via `Compress.init(output_writer, window, container, opts)` +
  `.writer.writeAll`/`.finish()`, one-shot decompress via
  `Decompress.init(input_reader, container, window)` +
  `.reader.allocRemaining`. Confirm `gzip`/`raw`/`zlib` container variants
  all round-trip. Confirm corrupt input surfaces as a catchable error, not a
  panic/crash.

## Phase 1: implementation slices

- [x] T1 Add `"zlib"` to `isStdNamespace` in `lumen_parser.zig`. New
  `zlibCallType` in `lumen_check_stdlib.zig` (mirrors `cryptoCallType`),
  wired into `staticCallType`. Alias in `lumen_check.zig`'s `Checker`
  struct.
- [x] T2 `needs_zlib_api: bool = false` flag on `ast.Program`.
- [x] T3 `zlib.gzipSync(data)` -- `string -> string`. Emit branch in
  `lumen_emit.zig`; shared runtime helpers `__zlibCompress`/
  `__zlibDecompress` (parameterized by `Container`, see T5) gated on
  `needs_zlib_api` in `lumen_compiler.zig`.
- [x] T4 `zlib.gunzipSync(data)` -- `string -> string`, `""` fallback on any
  decode error.
- [x] T5 `zlib.deflateSync(data)` / `zlib.inflateSync(data)` -- raw
  container variants, sharing the same helper functions parameterized by
  `Container`.
- [x] T6 Compile and run a real `.ts` test program after every slice, not
  just `zig build`.

## Phase 2: verification

- [x] T7 Round-trip: short string and ~100 KB repetitive string through
  `gzipSync`/`gunzipSync`; print compressed length to show real compression
  (ratio well above 1x on the repetitive input).
- [x] T8 Cross-check with system `gzip`: write `gzipSync`'s output to a
  `.gz` file, confirm `file`/`gunzip -c` on the host decode it correctly as
  real gzip framing.
- [x] T9 Raw vs. gzip size delta: confirm `deflateSync` output is exactly
  18 bytes smaller than `gzipSync` output for the same input (10-byte
  header + 8-byte footer, no zlib wrapper in between).
- [x] T10 Corrupt-input fallback: `gunzipSync` of non-gzip garbage returns
  `""`, no crash.
- [ ] T11 `zig build test` passes; one full clean non-concurrent
  `zig build conformance` shows 206 passed / 0 failed, no regressions.
- [x] T12 Update `website/stdlib.html`: quick-jump nav link, `<h4
  id="zlib">` section, per-function `<div class="api">` blocks with
  stability pills and the Buffer-less-string honesty note. Validate with
  `python3 html.parser`.
- [ ] T13 One focused commit, plain factual message, no AI attribution
  trailer.

## Phase 3 / deferred (tracked, not scheduled)

See spec.md's "Not planned" table: async `zlib.gzip`/`unzip`, streaming
`createGzip`/`createDeflate` transforms (needs a stream/duplex object type
the language doesn't have yet), brotli (not in this Zig version's
`std.compress` at all), zstd/xz/lzma wrappers (out of Node `zlib` module's
own scope), a compression-level option parameter, and separately-named
`deflateRaw`/`inflateRaw` (this module's `deflateSync`/`inflateSync` already
are the raw/headerless form).
