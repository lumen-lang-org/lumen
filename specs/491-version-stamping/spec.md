# 491 — lumen --version reports the release, not a constant (fixes #24)

## Problem

Every released `lumen` binary prints the same hardcoded string:

```
$ lumen --version
lumen 0.1.0-dev
```

`src/lumen.zig` declared `const lumen_version = "0.1.0-dev";` and never
changed it anywhere in the build or release path. Checked on the released
`lumen-x86_64-linux` archives for both v0.5.0 and v0.6.1: both print
`lumen 0.1.0-dev`. `--version` could not distinguish a release from any
other release, or a release from a local development build.

Filed as [lumen-lang-org/lumen#24](https://github.com/lumen-lang-org/lumen/issues/24).
Beyond cosmetics: a machine ran v0.5.0 for a day while its CI had moved to
v0.6.0 and then v0.6.1, and nobody noticed, because the one command that
would have revealed it answered `0.1.0-dev` regardless of what was
installed. It was eventually found by inspecting the tarball on disk. It
also degrades bug reports: an issue that says "reproduces on lumen
0.1.0-dev" carries no information.

## Fix

The release workflow already knows the version; it is the tag that
triggers it (`.github/workflows/release.yml` triggers on `push: tags:
"v*"`). The constant just needed to be stamped from that tag at build
time, the same way `joule-sh/code`'s release workflow stamps
`src/version.ts` from `${GITHUB_REF_NAME#v}` before building.

`lumen_version` moved out of `src/lumen.zig` into its own file,
`src/lumen_version.zig`, holding nothing but the constant:

```zig
pub const lumen_version = "0.1.0-dev";
```

`src/lumen.zig` now imports it:

```zig
const lumen_version = @import("lumen_version.zig").lumen_version;
```

The release workflow overwrites that whole file, per matrix target, right
after checkout and before the cross-compile step:

```sh
version="${GITHUB_REF_NAME#v}"
echo "pub const lumen_version = \"$version\";" > src/lumen_version.zig
```

A working-tree build never gets that overwrite, so `zig build` off a
checkout still reports `lumen 0.1.0-dev`, already distinguishable from any
tagged release (a release version never contains "dev").

## Verification

Working-tree build:

```
$ zig build && ./zig-out/bin/lumen --version
lumen 0.1.0-dev
```

Simulating the release workflow's stamping step exactly (`GITHUB_REF_NAME=v0.6.3`)
against a real build:

```
$ version="${GITHUB_REF_NAME#v}"
$ echo "pub const lumen_version = \"$version\";" > src/lumen_version.zig
$ zig build && ./zig-out/bin/lumen --version
lumen 0.6.3
```

`zig build test` passes. `zig build conformance`, compared against a fresh
baseline built from the same base commit, produces the same failing-case
set with no new failures (sorted FAIL lists diff empty).

A real tag push through the release workflow was not exercised; the
simulation above runs the workflow's stamping step verbatim against a real
compile rather than against a mocked build.
