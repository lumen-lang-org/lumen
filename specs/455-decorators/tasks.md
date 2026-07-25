# Tasks: Decorators

Three slices. Each lands on its own and leaves the compiler working; the
feature is only useful after the third.

## Slice 1 — syntax and description

- [ ] Lex `@` as a token where a declaration may begin.
- [ ] Parse `@name` and `@name(literal, ...)` before a type declaration, a
      field, a function declaration, and a parameter.
- [ ] Reject a non-literal argument with a message saying a decorator argument
      is metadata, not an expression.
- [ ] Carry `decorators: []Decorator` on the type, field, function and param
      AST nodes.
- [ ] Emit the description JSON for a decorated declaration, behind a hidden
      flag (`lumen describe <file>`), so the format can be exercised before
      anything runs it.
- [ ] Decorators are ignored by every later phase in this slice: a decorated
      program compiles exactly as it does today.

## Slice 2 — running one

- [ ] Resolve `@name` to an imported binding; a name that is not imported is an
      error saying so at the decorator's line.
- [ ] Check the bound function's signature is `(Description) => string`, and
      name the expected shape when it is not.
- [ ] Compile the decorator's module standalone, with a generated entry point
      that reads the description, calls the function and prints the result.
- [ ] Detect a cycle — a decorator module reaching the file it decorates — and
      report both files rather than recursing.
- [ ] Run the built binary, capture stdout as source and stderr as diagnostics.
- [ ] A decorator whose own module fails to compile reports as a failure of the
      decorator, naming it, not as a failure of the file being compiled.
- [ ] Append the output to the declaring file's source before parsing, in
      source order across several decorators.
- [ ] Run decorators for `check`, `compile`, `test` and `watch` alike.

## Slice 3 — errors and caching

- [ ] Retain generated source as an addressable unit, so a diagnostic inside it
      can name the decorator that produced it and show the offending line.
- [ ] Extend `g_line_map`, or the origin machinery beside it, to carry a
      generated origin distinct from a user file.
- [ ] A parse error in generated source names the decorator and shows the line.
- [ ] A check error in generated source does the same.
- [ ] Cache by hash of the description plus the binary's mtime; a rebuild with
      neither changed spawns nothing.
- [ ] `--no-decorator-cache` for debugging a decorator.

## Tests

- [ ] A decorator that echoes a fixed function makes it callable.
- [ ] Field decorators arrive with their arguments, in order.
- [ ] A function decorator receives parameters and return type.
- [ ] Two decorators on one declaration run in source order.
- [ ] A decorator that exits non-zero fails with its stderr, at its own line.
- [ ] Output that does not parse fails, attributed to the decorator.
- [ ] Output that does not check fails, attributed to the decorator.
- [ ] An unimported decorator name reports at its own line.
- [ ] A decorator function with the wrong signature names the expected one.
- [ ] A decorator module that imports the decorated file reports a cycle.
- [ ] A non-literal argument is refused with the specific message.
- [ ] Nothing changed: the second compile spawns no decorator.
- [ ] The binary changed: the next compile does spawn it.
- [ ] A decorator is unit-tested by calling it directly under `lumen test`,
      with no compiler involvement.

## Gates

- [ ] `zig build` and `zig build test` pass.
- [ ] One clean `zig build conformance` run: no new failures against the
      193 passed / 50 failed baseline.
- [ ] An undecorated program compiles byte-identically to before and pays
      nothing: no resolution, no build, no run.
- [ ] New examples land as conformance cases with a manifest wired into
      `build.zig`.

## Proving it

- [ ] std-contrib: an `entity` decorator generating a `plume` mapping from a
      decorated record, replacing the hand-written `repository(...)` list, with
      plume's existing tests passing against the generated one.
- [ ] std-contrib: a `tool` decorator generating an ai-package tool definition
      and its parameter schema from a decorated function — the second case that
      motivated this, and the check that the design is not shaped around one
      example.

## Deliberately not here

- [ ] Rewriting the decorated declaration. A decorator adds; it does not
      change what it is attached to.
- [ ] Hygiene. Generated names live in the flat namespace and collide through
      the ordinary duplicate diagnostic.
- [ ] Decorators that build other decorators, or any staging beyond one level.
- [ ] Decorators with side effects. The signature is a pure
      `(Description) => string`; anything wanting the filesystem or the network
      is a build step, not a decorator.
