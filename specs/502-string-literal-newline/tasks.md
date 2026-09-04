# Tasks: 502 raw newline in string literal

**Input**: spec.md, plan.md

## Phase 1: Lexer and diagnostic

- [ ] T001 Flag a `"`/`'` string token whose body contains `\n` or `\r`
  (`src/lumen_lexer.zig:291-312`).
- [ ] T002 Emit `W_STRING_NEWLINE` from the parser when the flag is set,
  through the same warnings list spec 229 uses.
- [ ] T003 Confirm `emitStrLit` escapes `\n`/`\r`; add a Zig unit test.

## Phase 2: Conformance

- [ ] T004 Add `examples/valid/newline.ts` (raw newline in a string, expected
  output pinned) and `examples/valid/template.ts` (raw newline in a template,
  no warning).
- [ ] T005 Add a `compile-warn` phase to `tools/lumen_conformance.zig`
  (`runCase`, `:176`): the compile MUST succeed and its stderr MUST contain
  `expect.diagnostic`. The existing `diagnostics` phase requires a failed
  compile, so a warning has no phase today.
- [ ] T006 Register `conformance/manifest.json` in `build.zig` beside the
  other manifests (`build.zig:116` pattern).
- [ ] T007 Run `zig build test` and `zig build conformance`; both green.

## Phase 3: Docs

- [ ] T008 Add the warning to the diagnostics list on the website
  (`website/learn.html` or wherever `W_UNUSED` is documented) and regenerate
  with `python3 website/genstdlib.py` / `stamp.py` if those files change.
- [ ] T009 `sh tools/codemap.sh` and commit the refreshed map.
