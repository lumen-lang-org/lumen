# Spec 504: `lumen compile --target node` — the JavaScript emitter

**Status**: Draft | **Parent**: 501, slice 3 | **Depends on**: 502, 503

## Goal

```sh
lumen compile --target node app.ts     # writes app.node/ with app.mjs + modules
node app.node/app.mjs
```

A second backend beside `lumen_emit*.zig` that turns the *checked* AST into
ECMAScript modules. The front end (lexer, parser, checker, optimizer passes,
decorator and `embed` rewrites, https fetching) is untouched; only the last
stage is replaced, the way `--wasm` replaces the link step
(`src/lumen.zig:2974 compileFile`, `:3140`).

This spec covers the language core and module layout. Byte strings and
integer arithmetic are spec 505; tests are 506; FFI is 507; the blocking
stdlib is 508. The gate for all of them is the same: every
`specs/*/examples/valid` program prints the same bytes under `node` as
natively.

## Output layout

```
app.node/
├── app.mjs                 # entry: imports globals, then the entry module
├── modules/<path>.mjs      # one per source module, https modules under modules/https/<host>/<path>.mjs
└── package.json            # {"type":"module"} so .mjs/.js both load as ESM
```

Module identity follows the source graph one to one, so a stack trace names
the user's file. Imports are rewritten to relative `.mjs` paths; the runtime
package (503) is imported by the entry file only, as
`@lumen-lang/node/globals` resolved through `--runtime <dir>` or the default
`packages/node-runtime` beside the compiler.

## Lowering table (language core)

| Lumen | JavaScript | Why not identity |
| --- | --- | --- |
| `import { T } from "./x.ts"` where `T` is a type | dropped | the checker knows (451); Node cannot |
| `export type`, `interface`, type aliases, generics, annotations | erased | |
| `import x from "https://..."` | `import x from "./modules/https/host/path.mjs"` | fetched by the front end already |
| `enum` (numeric, string, const) | frozen object literal | 003, 362, 386 |
| `class` with fields, accessors, `static`, `private` names | ES class | `#name` for private (473) |
| `constructor(private x)` | field assignment | 209 |
| `using x = ...` / `defer(fn)` | `try { } finally { x.dispose() }` in reverse order | 007, 027 |
| `Ref<T>` params | not reachable: FFI-only (024), rejected on this target by 507 | |
| `test(...)` | see 506 | |
| `JSON.parse<T>(s)` | `__json_parse(s, <validator for T>)` | 437, 483: the validator is generated per `T` |
| `embed(p)`, `embedDir(p)` | string / array literal | inlined at emit, as for Zig |
| `Class.nameOf`, decorators | already rewritten before emit | 455, 477 |
| `x as T`, `!` | erased | |
| `switch` without fallthrough (052/201) | as written; the checker already rejected fallthrough it forbids | |
| string literal with raw newline (502) | `\n` escaped | |
| `console.log(a, b)` | `console.log` via the runtime's byte-string aware `__log` (505) | |
| `throw new Error(m)` / `catch (e)` / `e.message` | identity | |
| `async`/`await`/`Promise` | identity, plus a top-level `await` guard | 479's ordering is Lumen's own; the Node target follows JavaScript's here, documented as the one intentional divergence |
| `process.env.K` / `process.env[k]` | `process.env(k)` (439's rewrite happens in the checker) | |
| numeric ops | see 505 | |

## CLI

- `--target node` on `compile`, `run`, `test`, `watch`, `check` (check is a
  no-op difference). Mutually exclusive with `--wasm`, `--static`, `--link`.
- `--out <dir>` overrides `<stem>.node/`.
- `--runtime <dir>` names the runtime package directory.
- `lumen run --target node app.ts` compiles then execs `node`.

## Diagnostics

- **E_TARGET_UNSUPPORTED**: a construct this target cannot lower yet, with
  the construct named and the spec that will add it (initially: `net`,
  `http`, `child_process.spawn`, `readline`, `Worker` — 508; `declare
  function` — 507).

## Requirements

- **FR-001**: `--target node` emits the layout above; `node <stem>.node/<stem>.mjs`
  runs the program.
- **FR-002**: every `specs/*/examples/valid` program whose native run
  succeeds and uses no 505/506/507/508 construct prints byte-identical
  stdout under Node. The conformance runner gains a `node-run` phase that
  asserts this against the native expectation.
- **FR-003**: the native and wasm targets are unchanged: `zig build
  conformance` green, generated Zig byte-identical for the whole corpus
  before and after (a `tools/emit_snapshot.sh` diff is part of the gate).
- **FR-004**: emitted JavaScript is readable: original identifiers, original
  statement order, one module per source file, no minification.
- **FR-005**: an unsupported construct reports `E_TARGET_UNSUPPORTED` at
  its source position, never a Node runtime error.

## Success criteria

- **SC-001**: `node-run` passes for the whole eligible corpus (list recorded
  in `conformance/corpus.txt` with the exclusion reason per excluded file).
- **SC-002**: Joule's pure modules (`protocol/`, `approval/`, `terminal/
  wrap.ts`, `text.ts`, `markdown.ts`) compile with `--target node` and their
  `.test.ts` files pass under 506.
- **SC-003**: emitter size stays under 3000 lines of Zig across
  `src/lumen_emit_js*.zig`; anything larger means the front end should have
  done the work.

## Not planned

| Item | Why |
| --- | --- |
| Source maps | the output keeps names and statement order; revisit with demand |
| Bundling into one file | modules mirror the source graph; a bundler can run on the output |
| CommonJS output | ESM only |
