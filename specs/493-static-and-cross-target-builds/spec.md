# 493 — lumen compile can name a target and ask for a static link (fixes #37)

## Problem

`lumen compile` always built for the host, with the host's libc, dynamically
linked. There was no flag for a target triple and none for a link mode, so the
glibc of whatever machine ran the compile became the floor for every machine
that would ever run the program:

```
$ lumen compile t.ts
$ ldd t
	libgc.so.1 => /lib/x86_64-linux-gnu/libgc.so.1
	libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6
```

Built on Ubuntu 24.04 that binary wants `GLIBC_2.36`, so it does not start on
Ubuntu 22.04 LTS (glibc 2.35, supported until 2027, and still what `wsl
--install` gives you), let alone on anything older. It also wants a
`libgc.so.1` the target machine has no reason to have.

Filed as [lumen-lang-org/lumen#37](https://github.com/lumen-lang-org/lumen/issues/37).

`--link` was the only flag that reached the backend, and it could not carry
this. `appendLink` turns a token with no `/` and no `.` into `-l<token>`, so
asking for a static link produced a missing-library error about a library
nobody named:

```
$ lumen compile --link -static t.ts
error: failed to build native binary for t.ts
  backend: error: unable to find dynamic system library '-static' ...
```

A token containing a `/` passes through verbatim, so a `@response-file` did
reach the backend — but only for a plain program. An async program is compiled
through the module form (`--dep xev -Mroot=… -Mxev=…`), and a response file
placed against that is read after the module arguments, where the target no
longer applies. The same flags, same source, same collector, only the delivery
differing:

```
# literal flags, module form: a static musl binary
$ zig build-exe -target x86_64-linux-musl -static -L$GC --dep xev -Mroot=… -Mxev=… …
# the same flags in a response file, module form: ignored
$ zig build-exe @rsp --dep xev -Mroot=… -Mxev=… …
error: undefined symbol: sigsetjmp
```

That `sigsetjmp` is the tell: the link had fallen back to the host's glibc, so
musl's copy was never in play. It failed silently in the sense that mattered —
the request was dropped, and what came out was a binary for the wrong target.
So every async program (anything with `setTimeout`, `Promise`, `async`/`await`,
or a server) could only ever be built for the host. One line reproduces it:

```ts
setTimeout(() => { console.log("hi"); }, 1);
```

## Fix

Two flags on `lumen compile`, spelled after the backend's own so there is one
thing to learn:

```sh
lumen compile --static app.ts                             # portable binary
lumen compile --target aarch64-linux-musl app.ts          # build for elsewhere
lumen compile --target aarch64-linux-musl --static app.ts
```

Three things had to be true for them to mean anything.

**They are placed ahead of everything else.** `-target`, `-static` and the
collector's `-L` are appended directly after `build-exe`, before the module
arguments and before any `-l`. That is what the response file could not do, and
it is why both compilation forms are covered by one insertion point: the plain
form and the async module form now differ only in what follows those flags.
Ordering is not cosmetic here — the collector has to be *found* before `-lgc` is
read, or the link resolves against the host's copy and fails on `sigsetjmp`.

**The collector is built for the target being built for.** The host's
`libgc.so` belongs to the host's libc and is no use to a build that is not for
the host; no distribution ships a musl build of it. So when a target is asked
for, the compiler builds one: bdwgc's single-translation-unit `extra/gc.c`,
through the backend's own C compiler, pinned by commit and cached per target
beside the libxev cache, the same fetch-and-cache shape `fetchLibxev` already
uses. `NO_GETCONTEXT` is not optional — musl has no `getcontext`, and without
it the link fails on that symbol; the collector uses `setjmp` for the same job.
The build costs ~30s once per target and is then reused.

**A request that cannot be honored is refused, out loud.** That is the whole
bug: a dropped request that produced a plausible-looking binary. So
`--target` parses the triple before anything is built for it, `--wasm` with
either flag is refused rather than silently winning, and `--static` against a
libc that cannot be linked statically is refused by name:

```
$ lumen compile --static --target x86_64-linux-gnu t.ts
error: --static cannot link the libc of 'x86_64-linux-gnu'; a static binary
needs musl (for example x86_64-linux-musl)
```

`--static` on its own has to resolve to *something*, and the host's glibc can
never be it. On Linux it retargets to `<host arch>-linux-musl` — same
architecture, same OS, the one libc that can be linked in — which is what makes
the flag usable without also knowing to name a triple. Elsewhere (macOS, where
no libc can be linked statically at all) there is nothing to fall back to and
the user is told to name a target.

`--link` keeps its behaviour for what it is documented to take — a library
name, a path, an object file — but now refuses a token that starts with `-`
rather than turning it into a library name that cannot exist:

```
$ lumen compile --link -static t.ts
error: --link takes a library name or a path, not a backend flag ('-static')
note: to choose a target or a link mode use --target <triple> and --static
```

Nothing changes for a compile that asks for neither flag: the argv is
byte-for-byte what it was, the host's `libgc` is still linked, and no download
happens.

## Verification

The one-line async reproduction from the issue, and a plain program, and a
larger async one (`async`/`await`, `Promise`, `setTimeout`, `Map`, `Set`,
array/string methods, `JSON.stringify`), all built on Ubuntu 24.04:

```
$ lumen compile --static t.ts && lumen compile --static a.ts && lumen compile --static big.ts
$ file a
a: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked
$ ldd a
	not a dynamic executable
```

Each of the three binaries then ran unchanged, with correct output, on Ubuntu
22.04 (glibc 2.35), Rocky Linux 8 (glibc 2.28) and Alpine 3.19 (musl) — the
floor is gone rather than lowered.

Cross-architecture: `--target aarch64-linux-musl --static` on the same async
program produces `ELF 64-bit LSB executable, ARM aarch64, statically linked`,
collector included, in one command.

Refusals: an unknown triple, `--static` against `x86_64-linux-gnu`, `--wasm`
alongside either flag, `--target` with no triple, and `--link -static` each exit
2 with the message quoted above, and build nothing.

No regression to the host path: a plain `lumen compile` still emits the same
dynamically linked binary against the system `libgc`, and `--wasm` is untouched.
`zig build test` passes, including new unit tests covering triple resolution and
which libcs can carry a static link. `zig build conformance`, compared against a
baseline built from the same base commit, produces the same failing-case set
with no new failures.

Not covered: static builds for Windows and for targets other than Linux are
allowed through to the backend but were not exercised here, and the collector
build for them is untested. Apple targets are refused outright, which is
correct — libSystem cannot be linked statically.
