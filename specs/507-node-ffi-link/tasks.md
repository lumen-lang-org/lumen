# Tasks: 507 FFI on Node

**Input**: spec.md, plan.md. **Depends on**: 504 phase 3.

- [ ] T001 Scan `// @link-node` per source file; ignore on native/wasm.
- [ ] T002 Emit one `import { ... } from "<shim>"` per file's externs;
  `E_FFI_NODE_LINK` when missing; `E_TARGET_UNSUPPORTED` for `Ref<T>`.
- [ ] T003 Copy shim modules into `modules/link/`.
- [ ] T004 Example with C and JS shims; manifest with `compile-run` and
  `node-run`; register in `build.zig`.
- [ ] T005 Gate green; document the pragma in `website/stdlib/ffi.html`;
  `stamp.py`; `codemap.sh`; commit.
