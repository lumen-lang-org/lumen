# Feature Specification: A library search path for compile

## Problem

`lumen compile` can name a library to link (`--link <lib>`) but cannot name a
directory to look for it in. For every library the backend finds on its own
that is fine. For one the caller has staged somewhere of its own choosing it
is not, and there is one case where staging it is the whole point: linking
the conservative collector statically, so a released binary does not depend
on a package manager being installed on the machine that runs it.

That case is real and is broken today. A downstream project stages `libgc.a`
in a directory of its own, then compiles with:

```
lumen compile --link -L$PWD/gcstatic app.ts
```

which spec 493 correctly began refusing: `--link` names a library, and
anything else it is handed becomes `-l<token>`, so `--link -static` used to
become `-l-static` and a request for a static binary looked like a missing
library. Refusing a backend flag is right. But `-L` was the one such token
that had no replacement, so the refusal left that project with no way to say
what it needs, and pinned to the last release before the refusal -- on macOS,
where it matters most, because Zig ignores `LIBRARY_PATH` there and knows
only Apple Silicon's Homebrew prefix, so there is no environment variable to
fall back to and no default directory to stage into on an Intel host.

## Scope

In scope:

- `lumen compile --library-path <dir>` (and `--library-path=<dir>`),
  repeatable, forwarded to the backend as `-L<dir>` in the order given.
- The `--link` refusal points at it when the rejected token starts with `-L`,
  since that is now a flag with a replacement rather than one without.

Out of scope:

- `lumen run`, `test`, `check`, `watch`. None of them take `--link` or
  `--target` either; the link surface lives on `compile`.
- Any change to what `--link` accepts. A backend flag stays refused.
- Searching for headers, or anything about `// @link` source pragmas.

## Design

`--library-path` joins `--target` and `--static` in `TargetSpec`, which is
already the set of flags that must reach the backend *before* the module
(`-M`) arguments an async build uses. A search path has the same requirement
for its own reason: a directory named after `-lgc` is read is a directory the
collector is not found in, which is exactly the failure the existing comment
in `compileFile` describes for the cross-target case.

Caller-named directories go ahead of the collector directory `compileFile`
builds for a non-host target, so a caller that stages its own collector gets
that one.

`isHost()` is unchanged and deliberately does not consider `lib_dirs`: naming
somewhere to look for a library says nothing about what is being built, and a
host build with `--library-path` is still a host build. Making it look like a
cross build would send it through `buildStaticGc`, which is the opposite of
what a caller staging their own collector asked for.

## Success Criteria

1. `lumen compile --library-path <dir> app.ts` links a library found only in
   `<dir>`, on a host build, with no other flag.
2. Repeating `--library-path` searches the directories in the order given.
3. `--library-path` with no argument is an error that says so.
4. `--link -L<dir>` still fails, and its note now names `--library-path`.
5. `--link -static` still fails with the note spec 493 gave it.
6. A host build without `--library-path` is unchanged.

## Notes

Verified by staging a `libgc.a` in a directory the backend does not search,
then compiling a program that allocates -- which fails with "unable to find
dynamic system library 'gc'" without the flag and links with it.
