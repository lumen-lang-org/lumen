# Tasks: 504 JavaScript emitter

**Input**: spec.md, plan.md. **Depends on**: 502 merged, 503 phase 2 done.

## Phase 1: Skeleton and gate

- [x] T001 `--target node` parsing in `src/lumen.zig` compile/run/test/watch;
  reject with `--wasm`/`--static`/`--link`. (`takeNodeFlag` serves every
  subcommand; `check` accepts it as a no-op; `test --target node` says it is
  spec 506's until then.)
- [x] T002 `CompileOptions.target: enum { native, wasm, node }` replacing the
  `wasm: bool` (keep `wasm` as a computed accessor so no call site changes).
  (Zig has no computed fields: the accessor is the method `wasm()`, and the
  seven call sites gained the parentheses.)
- [x] T003 `src/lumen_emit_js.zig` `emitProgram` producing the output layout
  for a `console.log("hi")` program; `compileFile` writes the directory.
  (`writeNodeOutput` in `src/lumen.zig`; the entry loads the program with
  `await import(...)` after the globals, see the comment there.)
- [x] T004 `node-run` phase in `tools/lumen_conformance.zig`: compile with
  `--target node`, run `node`, compare stdout with the case's `expect`.
  (Plus `node-diagnostics` for FR-005. The runner is now installed as
  `zig-out/bin/lumen-conformance` so one manifest can be run alone.)
- [x] T005 `tools/emit_snapshot.sh`: emit Zig for the whole corpus to a
  directory; a second run diffs. Wire as `zig build emit-snapshot`.
  (`LUMEN_EMIT_ZIG=<dir>` makes `lumen compile` keep the generated Zig and
  skip the backend; the diff against the pre-504 compiler was empty.)
- [x] T006 Manifest with the hello case; register in `build.zig`; green.

## Phase 2: Expressions and statements

- [x] T007 Literals, identifiers, binary/unary/ternary/coalesce/optional
  chains, calls, member access, index, template literals, arrows, object and
  array literals, spread/rest, destructuring (mirror `emitExpr` arms).
  (`src/lumen_emit_js_expr.zig`; operands are parenthesized by JavaScript's
  precedence table, so `a + b * c` prints as written. The checker packs a
  `...rest` call's trailing arguments into one array literal for the native
  slice; the emitter splices them back.)
- [x] T008 Statements: var decls, assignments, if/while/do/for/for-of/for-in,
  switch, return/throw/try/finally, break/continue, blocks, expression
  statements, `using`/`defer`. (`src/lumen_emit_js_stmt.zig`.)
- [x] T009 Walk `specs/001..052` corpus; add each passing program to
  `conformance/corpus.txt`; record exclusion reasons for the rest. (99
  programs in 001-049 -- 050-052 have no examples; 93 print identically,
  6 excluded with the reason in the file. The runner also runs a listed
  program's `compile-run` case as `node-run`, so every manifest's
  `zig build conformance` covers it.)
- [x] T010 List the checker's Zig-motivated in-place rewrites met so far and
  their JS treatment (plan §Risks); keep in plan.md.

## Phase 3: Modules and declarations

- [x] T011 Module boundary at emit time (plan context); per-module files.
  (The line map already names each statement's file; the expander now also
  records the import edges and the URL a module was named by, and the
  driver maps every file to `modules/<path>.mjs` relative to the directory
  the local modules share, URL modules under `modules/https/<host>/`.)
- [x] T012 Import rewriting, type-only import elision, `export` forms,
  https modules under `modules/https/`. (A module imports the names it
  refers to from the module that declares them and exports exactly what is
  imported; a source edge with no name becomes a bare import so the
  module's top-level code still runs, in the inlined order. Types are
  erased, so a type-only import leaves nothing to elide.)
- [x] T013 Classes (fields, ctor param properties, accessors, static,
  private names, inheritance, `super`), interfaces erased, enums.
  (`src/lumen_emit_js_class.zig`. A generic class's specializations are
  emitted where the template stood: the checker appends them after the
  code that uses them, and a class is not hoisted in JavaScript.)
- [ ] T014 `JSON.parse<T>` validators; `embed`/`embedDir`. (`embed` is
  done by the front end before parsing, so it needs nothing here. The
  validators landed under spec 505 T011: `JSON.parse<T>` passes T's shape
  to the runtime, which refuses what the native parser refuses with the
  same message (483) and revives a class instance without its constructor
  (456). What remains is a `#private` field on a revived instance, which
  JavaScript installs only by running the constructor: `corpus.txt` names
  the one program waiting on it.)
- [x] T015 Walk `specs/053..500` corpus; extend `corpus.txt`. (109 more
  programs: 84 print identically; 20 are 507/508 refusals; 467/roundtrip
  waits for 505's byte strings; 479/two-waiters-interleave is the
  documented `await`-ordering divergence; 456's two and 483's one need
  T014's validators and class revival.)

## Phase 4: Stdlib static calls and CLI

- [x] T016 `lumen_emit_js_stdlib.zig` table; Zig test cross-checking 503's
  `names.json`. (Static calls are identity -- the runtime package carries
  every name in Lumen's shape -- so the table holds the exceptions: the
  507/508 refusals, checked against `names.json` (embedded through
  `build.zig`, as `lumen.d.ts` is) so a refusal names a call the checker
  accepts and all of `net` is refused; and the instance methods the
  001-049 walk found: `find`/`at`/`pop`/`shift`/`Map.get` answer
  `undefined` for a miss and get `?? null`, `Map`/`Set` `keys`/`values`/
  `entries` answer iterators and get `Array.from`.)
- [x] T017 `E_TARGET_UNSUPPORTED` for 507/508 constructs. (`extern
  function`, a `Ref<T>` argument, an FFI call -> 507; `net.*`,
  `http.request`/`get`/`stream`/`createServer`, `child_process.spawn`,
  `Worker.run` -> 508, the calls the runtime package stubs. Pinned by the
  `node-diagnostics` cases in the manifest.)
- [x] T018 `lumen run --target node`, `--out`, `--runtime`. (`lumen test
  --target node` reports that it is spec 506's.)
- [ ] T019 Joule pure modules compile (`SC-002` list); note results in spec.

## Phase 5: Close

- [ ] T020 `zig build test`, `zig build conformance`, `emit-snapshot` diff
  empty, `node-run` green for `corpus.txt`.
- [x] T021 Website: a "Run on Node" section in `website/learn.html`;
  `stamp.py` (no asset changed, so nothing to restamp).
- [ ] T022 `sh tools/codemap.sh`; commit.

## Discovered while walking the corpus

- [x] T023a Native emitter: a class implementing a data-only interface
  (`interface Named { label: string }`) emitted `__vt_<Class>_Named:
  VT_Named = .{}` although no `VT_Named` is declared for an interface
  without methods, so `018/inheritance.ts` never built. `emitClassVtables`
  now skips such interfaces, as `emitIfaceDecl` already did.
- [x] T023b Native backend: `018/inheritance.ts` still failed after T023a.
  The Zig compiler error's line/col (attributed to `Animal.count += 1`) was
  the nearest preceding `__lumen_line`/`__lumen_col` marker, not the real
  site: `zig build-exe` on the emitted file pointed at `Counter.
  jsonStringify`'s `self` parameter. `Counter`'s only field (`private
  value`) is excluded from the private-state `jsonStringify` (spec 456), so
  the generated body never reads `self` -- an unused function parameter is
  a Zig compile error, not a warning. `emitClass` (`lumen_emit_class.zig`)
  now discards `self` there when the class has no public field to write.
  `emit_snapshot.sh` confirms this is the corpus's only front-end-output
  change since the pre-504 baseline; the rest of the corpus is untouched.
- [x] T023c `lumen compile --target node main.ts` with a bare file name
  wrote `modules/ain.mjs`: `nodeModulePaths` resolved the path without the
  working directory (`std.fs.path.resolve` no longer prefixes it), so the
  file's "directory" was `/` and the relative spelling lost its first byte.
  Found and fixed under spec 505 (its T014).
