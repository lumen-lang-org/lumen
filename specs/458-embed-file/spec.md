# Feature Specification: Embedding a File at Compile Time

## Problem

A program that needs a file's contents has two options today, and both give
something up.

Write it as a string literal, and anything longer than a few lines becomes
unreadable — escaped quotes, no editor support, no tooling. A hundred lines of
SQL as a Lumen string is not reviewable by the person most qualified to review
it.

```ts
migration("2", "create agents",
  "CREATE TABLE agents (\n" +
  "  id text PRIMARY KEY,\n" +
  "  team_id text NOT NULL REFERENCES teams (id)\n" +
  ")")
```

Read it with `fs.readFileSync`, and the program stops being one artifact. Lumen
compiles to a native binary; a binary that reads `./sql/V2__agents.sql` at
startup has to be deployed with a directory beside it, and a file that did not
ship is a runtime failure in production rather than an error at build time.

The std-contrib `plume` package shows the cost directly. Its migrations are a
plan of versioned steps, and the plan is better as a value than as a directory
of files — versions, checksums and ordering are checked, and a migration can be
*derived* from the mapping so the two cannot drift. But the SQL inside each
step wants to be a file.

## What it is

`embed(path)` is replaced, at compile time, by the contents of that file as a
string.

```ts
migration("2", "create agents", embed("./sql/V2__create_agents.sql"))
```

The file is read while compiling. Nothing reads it at run time, nothing ships
beside the binary, and a path that does not resolve is a compile error at the
line that wrote it.

## Scope

In scope:

- `embed("relative/or/absolute/path")` in expression position, producing a
  `string`.
- `embedDir("relative/or/absolute/path")` in expression position, producing an
  array of `{ name: string, text: string }` — one entry per regular file
  directly in that directory, sorted by name so a build is reproducible.
- The path is resolved against the source file that wrote it, not the working
  directory — the same rule `@link` follows, so a package that ships SQL beside
  its source works wherever it is compiled from.
- A path that is not a string literal is an error: the file is read before
  anything runs, so there is nothing to evaluate.
- A missing or unreadable file is an error naming the path and the line.
- The contents are bytes, embedded verbatim. No interpolation, no escaping
  rules, no encoding conversion.

Out of scope:

- Embedding as anything but a string — no byte arrays, no typed parsing.
- Globbing, or filtering by extension. `embedDir` takes every regular file
  directly in the directory; a directory holding things a program should not
  embed is the wrong directory to point at.
- Recursion into subdirectories. One level, so what a program contains stays
  readable from the program.
- Any interpretation of the file names. `embedDir` reports what it found;
  deciding that `V1__create_agents.sql` means version 1 is the caller's
  business, not the compiler's.
- A size limit beyond the compiler's existing one for source files.
- Caching: the file is read once per compile, which is already once.

## Design

### D1 — where it happens

`embed` is resolved during import expansion, beside `@link`, which already
resolves a relative path against the file that wrote it using the line map.
The call is replaced by a string literal before the parser sees it, so no
later phase needs to know the feature exists: the checker sees a string, the
emitter emits a string.

This is deliberately the least invasive option. `embed` is not a function —
there is nothing to call at run time — so giving it a signature the checker
must special-case would model it as something it is not.

### D2 — a directory

`embedDir` is the same substitution producing an array literal:

```ts
let files = embedDir("./sql");
// [{ name: "V1__create_teams.sql", text: "CREATE TABLE ..." }, ...]
```

Entries are sorted by name, so two builds of unchanged sources produce the
same program. Subdirectories and anything that is not a regular file are
skipped rather than reported, since a directory is pointed at for what it
holds, not for what it does not.

An empty or missing directory is an error, for the same reason a missing file
is: it is a build that will not do what it was written to do.

`name` is the file's own name, without any path. What it means — a version, an
order, a description — is the caller's to decide. The compiler does not know
what `V1__create_agents.sql` is.

### D3 — the path

Resolved against the directory of the file whose source wrote the call, as
`@link` is (`resolveLinkPath`). An absolute path is used as-is.

The scan must not mistake `embed(` inside a string literal or a comment for a
call, which is the flaw the pragma scanners have and get away with because
`// @link` only appears at the start of a line. Here the scan tracks string
and comment state.

### D4 — errors

- `embed(name)` where the argument is not a string literal: *the path must be
  a literal — the file is read while compiling, so there is nothing to
  evaluate*.
- The file does not exist or cannot be read: *cannot embed "<path>": no such
  file*, at the line of the call.

Both report at the line that wrote the call, in the file that wrote it, which
the line map already gives.

## Success Criteria

1. `embed("./fixture.txt")` produces the file's contents as a string.
2. A file containing quotes, backslashes and newlines embeds verbatim.
3. An empty file embeds as the empty string.
4. The path resolves against the source file, so a package embedding a file
   beside itself compiles from any working directory.
5. A missing file is a compile error naming the path and the line.
6. A non-literal argument is a compile error saying why.
7. The compiled binary does not open the embedded file at run time.
8. `zig build test` passes; `zig build conformance` adds no new failures.
9. `embedDir` on a directory of three files yields three entries, sorted, each
   with its own contents.
10. std-contrib: a plume migration plan built by pointing at a directory, with
    version and description read from each file name, and its tests passing
    against a live database.

## Notes

The value is that the two good properties stop being alternatives. The SQL
lives in a `.sql` file — reviewable, lintable, diffable by anyone who reads SQL
and not Lumen — and the program is still one binary with nothing beside it.

Zig has `@embedFile` and this compiler already uses it for its own resources;
this exposes the same idea to the language it compiles.
