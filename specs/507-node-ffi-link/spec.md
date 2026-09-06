# Spec 507: FFI on the Node target — `// @link-node`

**Status**: Implemented (SC-001, SC-002) | **Parent**: 501, slice 6 | **Depends on**: 504

## Goal

A `declare function` (025) names a function the program does not define.
Natively it is a C symbol from `// @link <obj>`. On Node it must come from
somewhere too. This spec makes that somewhere a JavaScript module named by
a second pragma, so one source file serves both targets:

```ts
// @link ./tty_shim.o
// @link-node ./tty_shim.mjs
declare function tty_isatty(fd: int): int;
declare function tty_cols(fd: int): int;
```

`tty_shim.mjs` exports `tty_isatty` and `tty_cols`. The emitter turns the
declarations into `import { tty_isatty, tty_cols } from "./tty_shim.mjs"`
(path resolved against the source file and copied into the output tree).

## Rules

- **FR-001**: `// @link-node <path.mjs>` is accepted anywhere `// @link`
  is; it is ignored by the native and wasm targets, as `// @link` is ignored
  by the Node target and `// @wasm-link` by both.
- **FR-002**: on the Node target a `declare function` with no `@link-node`
  in its file reports `E_FFI_NODE_LINK`: *"declare function X has no
  JavaScript implementation: add // @link-node <module.mjs> exporting X"*.
- **FR-003**: types cross as: `int`/`i32`/`i64`/`number`/`bool` → JS
  numbers/booleans; `string` (023) → a byte string (505), so a JS shim that
  wants text calls `Buffer.from(s, "latin1").toString()`; `Ref<T>` (024) →
  `E_TARGET_UNSUPPORTED` naming this spec's "Not planned" row.
- **FR-004**: the shim module is copied into `<out>/modules/link/` and
  imported relatively; it may itself import Node built-ins.

## Success criteria

- **SC-001**: `examples/valid/ffi.ts` with a C shim (native) and a JS shim
  (node) prints the same output on both targets.
- **SC-002**: Joule's `vendor/tty/tty.ts` and `vendor/platform/platform.ts`
  compile on the Node target with JS twins of their shims (written in Joule
  spec 004, T002) — done, including the tty read-with-timeout tests. Those
  do not need 508 after all: Node exposes no `poll()`, but the same
  non-blocking-fd technique any of its own I/O primitives use (a paused
  `tty.ReadStream`/`net.Socket` over the fd, then `fs.readSync` retried on
  `EAGAIN` under a deadline) gives a real timeout without a worker or
  `Atomics.wait` bridge — that machinery is for genuinely async sources
  (sockets, HTTP), not a blocking fd read. `tty.ts`'s 19 embedded tests and
  `platform.ts`'s 14 both pass under `lumen test --target node`, matching
  native exactly.

## Not planned

| Item | Why |
| --- | --- |
| `Ref<T>` on Node | out-params have no JS representation without a wrapper object; no known program needs it on Node |
| N-API addons through `@link-node` | a `.node` file can already be imported from the shim module with `createRequire`; nothing to add in the compiler |
