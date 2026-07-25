# Tasks: Decorators

Three slices. Each lands on its own and leaves the compiler working; the
feature is only useful after the third.

## Slice 1 — syntax and description

- [ ] Lex `@` as a token where a declaration may begin.
- [ ] Parse `@name` and `@name(literal, ...)` before a class declaration, a
      class member, a function declaration, and a parameter.
- [ ] Reject a non-literal argument with a message saying a decorator argument
      is metadata, not an expression.
- [ ] Carry `decorators: []Decorator` on the class, member, function and param
      AST nodes.
- [ ] Emit the description JSON for a decorated declaration, behind a hidden
      flag (`lumen describe <file>`), so the format can be exercised before
      anything runs it.
- [ ] Decorators are ignored by every later phase in this slice: a decorated
      program compiles exactly as it does today.

## Slice 2 — running one

- [x] Resolve `@name` to an imported binding; a name that is not imported is an
      error saying so at the decorator's line.
- [x] Check the bound function takes one `Description` and returns a type JSON
      can carry; name the expected shape when it does not, and name the
      offending field when the return type cannot be serialised.
- [x] Compile the decorator's module standalone, with a generated entry point
      that reads the description, calls the function, and prints its return
      value as JSON.
- [x] Detect a cycle — a decorator module reaching the file it decorates — and
      report both files rather than recursing.
- [x] Run the built binary, capture stdout as the value and stderr as
      diagnostics.
- [x] A decorator whose own module fails to compile reports as a failure of the
      decorator, naming it, not as a failure of the file being compiled.
- [x] Emit a constant named `<decorator><Declaration>`, of the decorator's
      declared return type, initialised to the returned value as a literal —
      not as a runtime parse. Emitted once the decorated declaration has closed,
      in source order across several decorators.
- [x] Run decorators for `check`, `compile`, `run` and `test` alike.

Two constraints this slice carries, both to be lifted rather than lived with:

- A decorator's module must export `Description` as well as the function. The
  entry point parses the description into it, and the compiler does not provide
  the type yet — so the module declares it, and every key the compiler writes is
  named there exactly once.
- A decorator can only read a description whose arguments are all strings.
  `args` is a JSON array of literals of any kind and Lumen has no type for a
  mixed array, so a decorator taking `@size(3)` cannot parse what it is handed.
  The arguments still reach the description; nothing can read them yet.

The constant lands directly after the declaration it belongs to rather than at
the end of the file: a top-level binding is not in scope before its own line,
so a constant appended after `main()` is one nothing can use.

## Slice 3 — errors and caching

- [ ] A returned value that does not fit the declared return type is reported
      at the decorator's line, naming the decorator, the field and both types.
- [ ] A generated constant whose name is already taken reports the collision
      naming the decorator that produced it, not just the duplicate binding.
- [ ] Cache by hash of the description plus the binary's mtime; a rebuild with
      neither changed spawns nothing.
- [ ] `--no-decorator-cache` for debugging a decorator.

## Tests

- [ ] A decorator returning a record produces a usable constant of that type.
- [ ] Field decorators arrive with their arguments, in order.
- [ ] A function decorator receives parameters and return type.
- [ ] Two decorators on one declaration run in source order.
- [ ] A decorator that exits non-zero fails with its stderr, at its own line.
- [ ] A return type that JSON cannot carry fails at the decorator's signature,
      naming the field.
- [ ] A generated constant colliding with a hand-written name names the
      decorator.
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

- [ ] std-contrib: an `entity` decorator returning a `DbRepository` from a
      decorated class, replacing the hand-written `repository(...)` list, with
      plume's existing tests passing against the generated one on all three
      databases.
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
- [ ] Decorators with side effects. The signature is a pure function of a
      description; anything wanting the filesystem or the network is a build
      step, not a decorator.
- [ ] Decorators returning source text. The return is a value with a declared
      type, so the whole path stays checked.
