# Tasks: 504 JavaScript emitter

**Input**: spec.md, plan.md. **Depends on**: 502 merged, 503 phase 2 done.

## Phase 1: Skeleton and gate

- [ ] T001 `--target node` parsing in `src/lumen.zig` compile/run/test/watch;
  reject with `--wasm`/`--static`/`--link`.
- [ ] T002 `CompileOptions.target: enum { native, wasm, node }` replacing the
  `wasm: bool` (keep `wasm` as a computed accessor so no call site changes).
- [ ] T003 `src/lumen_emit_js.zig` `emitProgram` producing the output layout
  for a `console.log("hi")` program; `compileFile` writes the directory.
- [ ] T004 `node-run` phase in `tools/lumen_conformance.zig`: compile with
  `--target node`, run `node`, compare stdout with the case's `expect`.
- [ ] T005 `tools/emit_snapshot.sh`: emit Zig for the whole corpus to a
  directory; a second run diffs. Wire as `zig build emit-snapshot`.
- [ ] T006 Manifest with the hello case; register in `build.zig`; green.

## Phase 2: Expressions and statements

- [ ] T007 Literals, identifiers, binary/unary/ternary/coalesce/optional
  chains, calls, member access, index, template literals, arrows, object and
  array literals, spread/rest, destructuring (mirror `emitExpr` arms).
- [ ] T008 Statements: var decls, assignments, if/while/do/for/for-of/for-in,
  switch, return/throw/try/finally, break/continue, blocks, expression
  statements, `using`/`defer`.
- [ ] T009 Walk `specs/001..052` corpus; add each passing program to
  `conformance/corpus.txt`; record exclusion reasons for the rest.
- [ ] T010 List the checker's Zig-motivated in-place rewrites met so far and
  their JS treatment (plan §Risks); keep in plan.md.

## Phase 3: Modules and declarations

- [ ] T011 Module boundary at emit time (plan context); per-module files.
- [ ] T012 Import rewriting, type-only import elision, `export` forms,
  https modules under `modules/https/`.
- [ ] T013 Classes (fields, ctor param properties, accessors, static,
  private names, inheritance, `super`), interfaces erased, enums.
- [ ] T014 `JSON.parse<T>` validators; `embed`/`embedDir`.
- [ ] T015 Walk `specs/053..500` corpus; extend `corpus.txt`.

## Phase 4: Stdlib static calls and CLI

- [ ] T016 `lumen_emit_js_stdlib.zig` table; Zig test cross-checking 503's
  `names.json`.
- [ ] T017 `E_TARGET_UNSUPPORTED` for 507/508 constructs.
- [ ] T018 `lumen run --target node`, `--out`, `--runtime`.
- [ ] T019 Joule pure modules compile (`SC-002` list); note results in spec.

## Phase 5: Close

- [ ] T020 `zig build test`, `zig build conformance`, `emit-snapshot` diff
  empty, `node-run` green for `corpus.txt`.
- [ ] T021 Website: a "Run on Node" section in `website/learn.html`;
  `stamp.py`.
- [ ] T022 `sh tools/codemap.sh`; commit.
