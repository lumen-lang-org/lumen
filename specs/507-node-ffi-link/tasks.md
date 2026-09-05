# Tasks: 507 FFI on Node

**Input**: spec.md, plan.md. **Depends on**: 504 phase 3.

- [x] T001 Scan `// @link-node` per source file; ignore on native/wasm.
  (`collectLinkNodeModules` in `lumen.zig`, the `// @link` scan's twin:
  same per-line marker, same `resolveLinkPath` relative-path rule, bucketed
  by the origin file `g_line_map` names. Only computed `if (out == .node)`,
  so native and wasm builds never see it -- `@link-node` lines are inert
  comments there, exactly as `@link` is on Node.)
- [x] T002 Emit one `import { ... } from "<shim>"` per file's externs;
  `E_FFI_NODE_LINK` when missing; `E_TARGET_UNSUPPORTED` for `Ref<T>`.
  (`lumen_emit_js.zig` `emitProgram`: one import per module that declared
  `extern`s, in declaration order, from `Emitter.linkNodeFor(file)`;
  `Emitter.ffiLinkMissing` when the file wrote none. The `Ref<T>` refusal
  already existed (spec 504's placeholder) and is untouched -- it is this
  spec's own "Not planned" row, not a future one. The `ffi_string_*`
  refusal in `lumen_emit_js_expr.zig`'s `.call` came out: FR-003 needs no
  marshalling on Node, a `string` is already a plain JS string (505), so
  the call falls through to the ordinary path.)
- [x] T003 Copy shim modules into `modules/link/`. (`writeNodeOutput` reads
  each `LinkNodeModule.disk_path` and writes it to `modules/<out>`, `out`
  computed alongside the scan as `link/<basename>`; the JS emitter's
  import specifier is `relativeSpecifier` to that same `out`, so the two
  never disagree.)
- [x] T004 Example with C and JS shims; manifest with `compile-run` and
  `node-run`; register in `build.zig`. (The example, both shims, and the
  `build.zig` registration were already checked in from the initial
  scaffold; verified by hand per plan.md, since the conformance runner
  does not build C objects: `zig cc -fno-sanitize=undefined -c shim.c -o
  shim.o && lumen run ffi.ts` prints `42`/`hello lumen` natively, matching
  `ffi.node`'s node-run expectation.)
- [x] T005 Gate green; document the pragma in `website/stdlib/ffi.html`;
  `stamp.py`; `codemap.sh`; commit. (Also `website/stdlib.html`, the
  one-page reference. `stamp.py --check` was already clean -- no CSS/JS
  touched.)

## Follow-up

- [ ] T006 SC-002 (Joule's `vendor/tty`/`vendor/platform` JS shims compiling
  and testing under the Node target) needs the Joule repository and is not
  verified here; this round only implements and verifies the compiler
  feature (SC-001) and the fix that motivated it (`ffi.node` failing the
  full conformance sweep). Pick this up with Joule attached.
