# Tasks: 505 byte strings and integers

**Input**: spec.md, plan.md. **Depends on**: 504 phases 1–3.

## Phase 1: Strings

- [x] T001 Emit string literals as UTF-8 bytes with `\xNN` escapes.
  (`writeLitByte` in `lumen_emit_js.zig`: every byte at or above 0x7f is
  `\xNN`, in string literals, template text and regex sources alike, so a
  pattern matches the bytes it was written as.)
- [x] T002 `String.fromCodePoint`, `codePointAt`, case methods,
  `localeCompare`, `normalize` via `__lang`; every other `stringMethod`
  name gets an identity arm (list them in `lumen_emit_js_stdlib.zig`).
  (`string_methods` there names every method the checker accepts --
  `lumen_check_methods.zig` now exports `string_method_names` and a test
  checks the two lists agree. Helpers: `charCodeAt`/`codePointAt` (-1 past
  the end), ASCII-only case, `trim*` (space/tab/CR/LF only), byte-order
  `localeCompare`, `repeat` (negative is ""), string-pattern
  `replace`/`replaceAll` (literal replacement, empty pattern matches
  nothing). `normalize` is not a method the checker accepts, so there is
  nothing to lower. `String.fromCodePoint`/`fromCharCode` are the runtime's
  overlays, which now capture the JavaScript originals before the overlay
  replaces them -- `fromCodePoint` recursed into itself -- and mask
  `fromCharCode` to a byte.)
- [x] T003 Runtime boundary audit: every `lib/*.mjs` function converts text
  with `latin1`; delete the `LUMEN_STRINGS` switch; `url.parse` decodes
  before `new URL`. (Audited: `fs`, `process`, `os`, `path`, `child_process`,
  `crypto`, `zlib`, `streams`/`readline`, `assert` all go through
  `toBuffer`/`fromBuffer`/`bytes`/`text`; `url.parse` is a byte-safe regex
  over the input, no `URL` object, so nothing to decode. The switch is gone
  from `lang.mjs`, `index.mjs`, the tests and the README. The one boundary
  that was missing is the console: `globals.mjs` installs a console whose
  printing methods decode byte strings wherever they sit in a value
  (`lang.mjs` `printable`), since Node's formatter writes text.)
- [x] T004 `JSON.parse`/`stringify`/`Buffer` in `lib/lang.mjs` and
  `lib/buffer.mjs` per Decision 1. (`stringify` over byte strings is
  JavaScript's own -- every code unit is copied verbatim and the escapes it
  adds are ASCII. `parse` decodes the document to text, parses, and
  re-encodes every string, keys included (`lang.mjs` `jsonParse`, installed
  as `JSON.parse`/`parseOpen`). `Buffer` already went through
  `toBuffer`/`fromBuffer`, which are latin1-only now.)
- [x] T005 Corpus programs: `bytes.ts`, `roundtrip.ts`, `hot_path.ts`
  (with the no-helper grep test), `json_utf8.ts`. (The grep test is a unit
  test in `lumen_emit_js.zig` that compiles `hot_path.ts`, embedded through
  `build.zig`, and expects no `__lang.` in the module. 504's `corpus.txt`
  regains `001/division.ts` and `467/roundtrip.ts`, which this spec
  unblocked.)

## Phase 2: Integers and numbers

- [x] T006 Integer `/`, `/=`, `%` by static type; `__lang.divInt`.
  (`isIntDivision` in `lumen_emit_js_expr.zig` mirrors the native
  `@divTrunc` decision: anything but an `f64` result. `/=` on a local uses
  `Assign.checked_type`; on a field, `MemberAssign` gained `checked_type`,
  set by `assignField`, which the native emitter now uses too instead of
  assuming `i32` for `<<=`/`>>=`/`**=`/`/=`. `assignField` also promotes an
  integer operand on a `number` field and an `i32` on an `i64` field, as a
  local's compound assignment already did. `%` is identity.)
- [x] T007 `W_I64_PRECISION`; `bigint`/`Nn` literals as numbers. (The
  lexer already drops the `n`, so a `bigint` literal is an `i64` `.num`; the
  emitter warns once per program on the first literal past 2^53, through
  the `warnings` sink `CompileOptions` already carried for the checker.)
- [x] T008 Numeric formatting parity for the numeric corpus; `__lang.fmt`.
  (Specs 136/181/107/110/364/433 have no example programs, so the corpus is
  the `examples/valid` programs plus `compound.ts` here. `fmt` writes every
  digit where JavaScript switches to `1e+21`/`1e-7`, and `nan`/`inf`; the
  emitter routes a `number` through it at `String(x)` (the checker now
  records the operand type in `call.stringify_type`), `${x}`, and
  `x.toString()`; the console formats a top-level number argument the same
  way. A namespace constant (`Math.PI`, `Number.NaN`) is emitted as its
  call, so the value is the number rather than the runtime's callable.
  Left as documented divergences: `toFixed` where the native rounding
  differs from JavaScript's exact-decimal one (`(1.005).toFixed(2)`), and
  `toFixed` of a value at or past 1e21; neither is in the corpus.)
- [x] T009 Corpus program `ints.ts`. (Plus `compound.ts`: `/=` and `%=` on
  locals and fields, `i64` division, negative `%`, constants, `1e21`.)

## Phase 3: Close

- [x] T010 Manifest cases on both phases; register in `build.zig`. (12
  cases, six programs, each `compile-run` and `node-run`; the manifest was
  already registered.)
- [ ] T011 Joule `text.test.ts`, `markdown.test.ts`, websocket frame tests
  under `lumen test --target node` (506); record in spec SC-002. (Blocked:
  `lumen test --target node` is spec 506's and refuses today.)
- [ ] T012 Gate: `zig build test`, `zig build conformance`, `emit-snapshot`
  diff empty, `node-run` for `corpus.txt`.
- [x] T013 Document Decision 1 in `website/stdlib/strings.html` ("on the
  Node target, strings are bytes too"); `stamp.py`; `codemap.sh`; commit.
  (The `fromCodePoint` row there still described spec 119's byte-masking;
  it now says what spec 472 made it. No asset changed, so `stamp.py
  --check` is clean.)

## Discovered while walking the corpus

- [x] T014 `lumen compile --target node main.ts` (a bare file name) wrote
  the module as `modules/ain.mjs`: `nodeModulePaths` resolved the path
  without the working directory, so its "directory" was `/` and the
  relative spelling dropped a character. It now roots relative paths at the
  cwd (`std.process.currentPathAlloc`).
