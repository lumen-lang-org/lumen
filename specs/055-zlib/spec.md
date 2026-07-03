# Spec 055: zlib (gzip/deflate compression)

## Goal

A practical subset of Node's `zlib` module: one-shot gzip and raw-deflate
compress/decompress, matching the shape of the existing `crypto` namespace
(pure static functions, no stateful stream object) rather than Node's
`zlib.createGzip()` transform-stream style -- Lumen has no stream/Buffer
object model to hang a stateful compressor off of yet.

## API

| Function | Type | Notes |
| --- | --- | --- |
| `zlib.gzipSync(data)` | `string -> string` | compresses `data`'s bytes into a real gzip container (10-byte header + deflate body + CRC32/size footer, RFC 1952) |
| `zlib.gunzipSync(data)` | `string -> string` | inverse of `gzipSync`. On any decode error (bad header, truncated stream, checksum/size mismatch, or just non-gzip garbage) returns `""` rather than throwing -- see Failure shape below |
| `zlib.deflateSync(data)` | `string -> string` | raw deflate body only, no gzip/zlib header or footer (RFC 1951) |
| `zlib.inflateSync(data)` | `string -> string` | inverse of `deflateSync`; same `""`-on-error fallback as `gunzipSync` |

All four are namespace-static calls, matching `Math.*`/`path.*`/`crypto.*`.
No `zlib.gzip`/`zlib.unzip` async/callback variants, no `zlib.createGzip()`
stream, no `zlib.deflateRaw` vs `zlib.deflate` (zlib-wrapper) distinction as
separate named functions -- see Not planned.

## Buffer-less v1 shape

Lumen's `string` type is `[]const u8` -- raw bytes, not validated UTF-8 (an
existing, already-documented property of the language; see `crypto.sha256`
and `crypto.randomBytes`, which already return/consume non-UTF-8-safe byte
sequences through `string`). Compressed gzip/deflate output is binary and
will routinely contain byte values that aren't valid UTF-8 on their own --
that's fine and expected under this representation. This is deliberately the
same "no `Buffer` type yet" shape `crypto.randomBytes` already documents:
a future `Buffer`/`Uint8Array`-like type would be the natural home for
binary data, and this module would likely grow `zlib.gzipSync(buf) ->
Buffer` variants at that point. Until then, `string` is the only byte-carrying
type available, so it carries compressed bytes too.

## Design notes -- verified directly against this Zig version's source

The `std.compress` API has churned across Zig versions, so nothing below is
assumed from memory -- confirmed by reading
`lib/std/compress/flate.zig`/`flate/Compress.zig`/`flate/Decompress.zig` in
the exact toolchain this repo builds with (0.16.0) and by round-tripping a
standalone Zig program before writing any compiler code.

- **Container support is real, built into `std.compress.flate` itself**:
  `std.compress.flate.Container` is an enum of `raw` / `gzip` / `zlib`, and
  `Compress.init`/`Decompress.init` both take a `Container` value directly --
  the gzip 10-byte header + CRC32/size footer (RFC 1952) and the zlib 2-byte
  header + Adler32 footer (RFC 1950) are handled internally, not something
  this module needed to hand-roll.
- **One-shot compress**: `Compress.init(output: *Writer, window: []u8,
  container, .default)` wraps an output `std.Io.Writer`; write the
  uncompressed bytes to `compress.writer.writeAll(data)`, then
  `compress.finish()` flushes the final block and writes the container
  footer. The output writer used here is `std.Io.Writer.Allocating`
  (a growable in-memory writer over `__alloc`) so the compressed size isn't
  known up front -- confirmed this is a real, intended use of the type (it's
  the same "write to a growable buffer" primitive used elsewhere in std, not
  a hack). `Compress.init` asserts `output.buffer.len > 8`, so the
  `Allocating` writer must be given starting capacity via `initCapacity`
  first -- an empty `.init(alloc)` starts with a zero-length buffer and trips
  the assert (hit this directly in the de-risk program; documented under
  Bugs below even though it's a de-risk-time finding, not a shipped bug).
- **One-shot decompress**: `Decompress.init(input: *Reader, container,
  window: []u8)` wraps an input `std.Io.Reader` (`std.Io.Reader.fixed(data)`
  over the compressed bytes already in memory); `decompress.reader
  .allocRemaining(alloc, .unlimited)` pulls the fully-inflated bytes into a
  fresh allocation. Confirmed this surfaces container-format errors (bad
  magic bytes, bad checksum, truncated stream) as a `Reader` error rather
  than silently returning partial/garbage data -- the corrupt-input test in
  this spec's verification checks this directly.
- **Window buffer**: both `Compress` and `Decompress` require a caller-owned
  scratch buffer of at least `flate.max_window_len` (65536 bytes, confirmed
  from `history_len = 32768` doubled). Allocated via `__alloc` in the
  generated runtime helpers rather than put on the stack, to avoid growing
  every call site's stack frame by 64 KiB.
- **Compression level**: `Compress.Options.default` (`level_6`, matching
  zlib's own default level per the option table's doc comment) -- no reason
  to expose a level knob in v1 when Node's own `zlib.gzipSync` defaults are
  rarely overridden either.
- **Failure shape**: matches this codebase's existing "fallback, don't
  crash" convention for parse-shaped stdlib calls (compare
  `url.parse` returning a best-effort record rather than throwing on a
  malformed URL). `gunzipSync`/`inflateSync` catch every `Decompress`
  reader error and return `""`. This is a deliberate, documented behavior,
  not a bug: a real gzip stream never decodes to `""` in-band (an empty
  *input* still produces valid, non-empty gzip framing bytes when
  compressed), so `""` is unambiguous as an error sentinel given the
  current no-`Result`/no-exceptions-across-this-boundary language shape.

## Verification plan

- Round-trip a short string and a ~100 KB repetitive string through
  `gzipSync`/`gunzipSync`, printing the compressed length to show real
  compression happened (not just pass-through).
- Cross-check against the system `gzip`/`gunzip` binaries: write Lumen's
  `gzipSync` output to a file with the `.gz` extension and confirm
  `file`/`gunzip -c` on the host recognize and correctly decode it as a real
  gzip stream -- proof this is genuine RFC 1952 framing, not a private
  format.
- Round-trip through `deflateSync`/`inflateSync` (raw, no container) and
  confirm the raw output is smaller than the gzip form of the same input by
  exactly the container overhead (18 bytes: 10-byte gzip header + 8-byte
  footer), demonstrating the container/raw distinction is real.
- Corrupt-input fallback: feed non-gzip garbage bytes into `gunzipSync` and
  confirm `""` comes back rather than a crash/panic.

## Not planned (this pass)

| Item | Why |
| --- | --- |
| `zlib.gzip`/`zlib.unzip` (async, callback or Promise-based) | every other stdlib module's `*Sync` functions ship before their async twins get a dedicated pass (see `fs.readFileSync` predating `fs.readFile`'s thread-pool design in spec 047); compression is comparatively rare on a hot path, sync-first is the right order here too |
| `zlib.createGzip()`/`createDeflate()` streaming transform | needs a stateful stream/duplex object the language doesn't have yet (see spec 046 streams' scope); one-shot whole-buffer compression covers the overwhelming majority of real uses (config blobs, HTTP response bodies already fully buffered, small payloads) |
| Brotli (`zlib.brotliCompressSync`/etc.) | not in `std.compress` at all in this Zig version (only `flate`, `zstd`, `lzma`/`lzma2`, `xz` directories exist under `lib/std/compress/`) -- would require vendoring a C library or a from-scratch implementation, out of scope for a stdlib wrapper module |
| zstd/xz/lzma wrappers | `std.compress.zstd`/`xz`/`lzma` exist and could get their own future spec, but Node's `zlib` module itself only covers gzip/deflate/brotli, and this spec is scoped to matching that module's name and surface, not exposing everything `std.compress` happens to ship |
| A compression-level parameter (`{ level: N }` option object) | the language's stdlib wrappers so far are plain positional-arg functions (see `crypto.randomBytes(n)`, not an options-object style); `Compress.Options.default` is a sane default and a level knob can be added as an optional second argument later without breaking this API |
| `zlib.deflateRaw`/`zlib.inflateRaw` as separately-named functions from `zlib.deflate`/`zlib.inflate` | Node has this split because its `deflate`/`inflate` default to the zlib-wrapped container (RFC 1950) while `*Raw` means headerless. This module names the headerless form `deflateSync`/`inflateSync` directly (matching the container enum's three-way `raw`/`gzip`/`zlib` split) and doesn't expose the RFC-1950 zlib-wrapper container as a fifth/sixth named function since gzip already covers the "give me a self-describing container" use case |
