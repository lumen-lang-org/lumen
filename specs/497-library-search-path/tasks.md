# Tasks: A library search path for compile

## Investigation

- [x] Confirm there is no existing way to name a search path: `-L` reaches
      the backend only from `compileFile`'s own `buildStaticGc` for a
      non-host target, and `--link` refuses any token starting with `-`.
- [x] Confirm `// @link` pragmas and `--link` share `appendLink`, which
      turns a token with a `/` or `.` into a path and anything else into
      `-l<token>` -- so an absolute path to `libgc.a` does link, but the
      unconditional `-lgc` that follows still resolves against the
      backend's own search paths and fails. A path is not a substitute for
      a search path.
- [x] Confirm placement matters: the existing comment in `compileFile`
      records that the collector has to be searched for before `-lgc` is
      read, which is why `lead` exists.

## Implementation

- [x] `TargetSpec.lib_dirs`, defaulted empty so every existing
      `compileFile` caller is untouched.
- [x] `-L<dir>` appended to `lead` in order, ahead of the non-host
      collector directory.
- [x] `--library-path <dir>` and `--library-path=<dir>` parsed in the
      `compile` branch, repeatable; missing argument is an error.
- [x] `--link`'s refusal note names `--library-path` when the rejected
      token starts with `-L`.
- [x] `usage` lists the flag.
- [x] `isHost()` left alone, with a comment saying why a search path is not
      part of it.
- [x] `docs/CODEMAP.md` regenerated (`sh tools/codemap.sh`).

## Verification

- [x] `zig build` passes.
- [x] `zig build test` passes.
- [x] `zig build conformance` matches the pre-change baseline.
- [x] A `libgc.a` staged in a directory the backend does not search: an
      allocating program fails to link without the flag ("unable to find
      dynamic system library 'gc'") and links with it.
- [x] `--library-path` with no argument errors and says what it needs.
- [x] `--link -L/tmp/x` errors and names `--library-path`; `--link -static`
      errors and names `--target`/`--static`, unchanged.

## Follow-up (not this slice)

- [ ] Nothing here covers where *headers* are searched for. No caller has
      asked, and C FFI in this repo is archive-shaped, not header-shaped.
