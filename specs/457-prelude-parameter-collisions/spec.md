# Feature Specification: Prelude Parameter Collisions

## Problem

A program cannot declare a top-level function named `label`, `path`, `value`,
`name`, `key`, `text`, `id`, `line`, `field`, `target`, `total` — or about
ninety other ordinary words — if it also uses the standard-library call whose
generated prelude function happens to take a parameter of that name.

```ts
function label(x: string): string { return "[" + x + "]"; }

function main(): void {
  let code = process.argv.length;      // pulls in the process prelude
  console.log(label("n"), `${code}`);
}
main();
```

```
lbl.ts:5:3: error: function parameter shadows declaration of 'label'
note: the native backend rejected this statement's generated code —
      likely a Lumen compiler bug; please report it
```

The prelude function is `__processStatusField(text: []const u8, label: []const
u8)` in `src/lumen_runtime_os.zig:530`. Zig rejects a parameter that shadows a
top-level declaration, and the user's `label` is one.

Two things are wrong. The program is rejected for a reason that has nothing to
do with it, and the message says the opposite of the truth: it invites a bug
report about a rule the language does mean to have — a parameter really cannot
shadow a top-level name here, because every module shares one namespace.

## Why it is worth fixing

The names are not exotic. Collecting every parameter of every emitted prelude
function gives, among others:

```
name path value key data text id url method body headers port host prompt
command signal mode flags target prefix suffix line field label total parts
msg args flag encoding recursive iterations salt handler listener
```

`path`, `name`, `value` and `key` are among the most likely names in any
program. Which of them is fatal depends on which standard-library calls the
program happens to make, so the failure appears when an unrelated line is
added, and points at the call rather than at the declaration.

This also blocks a decorator module (spec 455) from declaring a top-level
`label` or `sig`, because the generated entry point pulls in the process
runtime whether the decorator wants it or not.

## Scope

In scope:

- A top-level declaration may use any name the language allows, whatever the
  prelude happens to call its parameters.
- The existing shadowing diagnostic (`E_PARAM_SHADOWS`) stays: a *user's*
  parameter shadowing a *user's* top-level name is still an error, since that
  one is about the language's flat namespace and is worth stating.

Out of scope:

- Changing the flat namespace itself.
- Prelude *function* names, which spec 139 already renames around.

## Design

### D1 — the prelude owns its parameter names

The generated Zig is an artifact, so the prelude's parameter names are not
anybody's API. Give every prelude function's parameters a spelling no user
declaration can take. `__` is the existing convention for compiler-emitted
names and is already unavailable to user code.

```zig
fn __processStatusField(__text: []const u8, __label: []const u8) i64 {
```

Nothing outside the prelude refers to these names, so the change is confined
to the runtime source files, and no user-facing behaviour changes except that
more programs compile.

### D2 — the rename must be per-function, not per-file

The prelude is embedded Zig inside Zig string literals across
`lumen_runtime_fs.zig`, `lumen_runtime_net.zig`, `lumen_runtime_os.zig` and
the compiler's own prelude text. A whole-file substitution would also rewrite
struct field names (`.path = path`), string contents (`"VmRSS:"`), and calls
into std. The rename applies inside one `fn __...(...) { ... }` block at a
time, to identifier occurrences only — not after a `.`, not inside a string.

### D3 — a test that keeps it fixed

A conformance case per runtime area, declaring a top-level function named
after one of that area's prelude parameters and calling into it:

```ts
function path(p: string): string { return p; }
function main(): void { console.log(path(fs.existsSync("/tmp") ? "y" : "n")); }
main();
```

## Success Criteria

1. The reproduction above compiles and prints `[n] 1`.
2. A top-level `path`, `name`, `value`, `key` and `text` each compile
   alongside the fs, net, os and process calls whose preludes use them.
3. `E_PARAM_SHADOWS` still fires for a user parameter shadowing a user
   top-level name.
4. `zig build test` passes; `zig build conformance` adds no new failures.

## Notes

Found while building the std-contrib `plume` package: a test helper named
`target` collided with the SQLite driver's `connect: (target: string)`, and a
decorator module could not declare `label`. The first was a user-to-user
collision, which is the language's rule and now has a proper diagnostic. The
second is this — a rule the user has no way to know about, enforced by an
error message that blames the compiler.
