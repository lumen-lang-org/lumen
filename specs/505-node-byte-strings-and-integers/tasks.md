# Tasks: 505 byte strings and integers

**Input**: spec.md, plan.md. **Depends on**: 504 phases 1–3.

## Phase 1: Strings

- [ ] T001 Emit string literals as UTF-8 bytes with `\xNN` escapes.
- [ ] T002 `String.fromCodePoint`, `codePointAt`, case methods,
  `localeCompare`, `normalize` via `__lang`; every other `stringMethod`
  name gets an identity arm (list them in `lumen_emit_js_stdlib.zig`).
- [ ] T003 Runtime boundary audit: every `lib/*.mjs` function converts text
  with `latin1`; delete the `LUMEN_STRINGS` switch; `url.parse` decodes
  before `new URL`.
- [ ] T004 `JSON.parse`/`stringify`/`Buffer` in `lib/lang.mjs` and
  `lib/buffer.mjs` per Decision 1.
- [ ] T005 Corpus programs: `bytes.ts`, `roundtrip.ts`, `hot_path.ts`
  (with the no-helper grep test), `json_utf8.ts`.

## Phase 2: Integers and numbers

- [ ] T006 Integer `/`, `/=`, `%` by static type; `__lang.divInt`.
- [ ] T007 `W_I64_PRECISION`; `bigint`/`Nn` literals as numbers.
- [ ] T008 Numeric formatting parity for the numeric corpus; `__lang.fmt`.
- [ ] T009 Corpus program `ints.ts`.

## Phase 3: Close

- [ ] T010 Manifest cases on both phases; register in `build.zig`.
- [ ] T011 Joule `text.test.ts`, `markdown.test.ts`, websocket frame tests
  under `lumen test --target node` (506); record in spec SC-002.
- [ ] T012 Gate: `zig build test`, `zig build conformance`, `emit-snapshot`
  diff empty, `node-run` for `corpus.txt`.
- [ ] T013 Document Decision 1 in `website/stdlib/strings.html` ("on the
  Node target, strings are bytes too"); `stamp.py`; `codemap.sh`; commit.
