# Plan: 507 FFI on Node

- Pragmas: `// @link` is scanned in `src/lumen.zig` (search `"// @link "`;
  the `@wasm-link` marker at `:2880` is the model). Add `@link-node`
  collection returning the module path per source file.
- Declarations: `ExternDecl` (`lumen_ast.zig:149`), declared by
  `declareExtern` (`lumen_check_stmt.zig:43`). The JS emitter groups the
  file's externs into one import statement from the file's `@link-node`
  module.
- Copy the shim into the output tree in the module writer (504 T011).
- Example: `examples/valid/shim.c` and `examples/valid/shim.mjs` implement
  the same two functions. The conformance runner does not build C objects
  (009's case links libm only), so the manifest carries the `node-run` case
  and the native side is verified by hand in T004: `zig cc -c shim.c -o
  shim.o && lumen run ffi.ts` from the example directory.
