# Feature Specification: Decorators

## Problem

A declaration cannot carry metadata, so anything that needs to know a type's
shape must be written out by hand beside it. The std-contrib `plume` package
shows the cost: mapping a record to a table means restating every field the
record already declares.

```ts
type Agent = {
  id: string,
  agentName: string,
  maxSteps: int,
};

// The same three fields again, by hand, kept in step by discipline alone.
let repo = repository("agents", "id", "id", [
  field("id", "id", "text"),
  field("agentName", "agent_name", "text"),
  field("maxSteps", "max_steps", "int"),
]);
```

The same shape appears wherever a declaration's structure is needed twice: a
tool's parameter schema beside its function, a serializer beside a record, a
route table beside its handlers.

Java attaches this with `@Entity`/`@Column` and reads it back by reflection.
There is no reflection here and there will not be — the product is a compiled
binary with no runtime type information. So a decorator here cannot be a
runtime hook. It has to be **code generation at compile time**.

## What a decorator is

A decorator is a Lumen program the compiler runs while compiling. It receives a
description of the declaration it was attached to, and returns Lumen source
that is spliced into the program.

```ts
@entity("agents")
type Agent = {
  @column("agent_name", "text")
  agentName: string,
  @id @column("id", "text")
  id: string,
};
```

`@entity` is not known to the compiler. It resolves to a program that reads:

```json
{
  "kind": "type",
  "name": "Agent",
  "args": ["agents"],
  "fields": [
    { "name": "agentName", "type": "string",
      "decorators": [{ "name": "column", "args": ["agent_name", "text"] }] },
    { "name": "id", "type": "string",
      "decorators": [{ "name": "id", "args": [] },
                     { "name": "column", "args": ["id", "text"] }] }
  ]
}
```

and writes:

```ts
export function agentRepository(): DbRepository { ... }
export function findAgent(id: string): Agent { ... }
```

Anyone can write one. The compiler knows the syntax and the protocol, never the
vocabulary — there is no built-in `@entity`, `@tool` or `@route`, and adding
one requires no compiler change.

## Why a subprocess

The compiler has no interpreter — that path was deliberately dropped, and the
generated Zig is the product. So user code can only run at compile time if it
is first compiled to a binary and then executed. That is staged compilation,
and `child_process.spawn` (spec 450) already provides the mechanism.

It also keeps the protocol honest: JSON in, source out, over a pipe. A
decorator is an ordinary program that can be run and tested by hand, without
the compiler in the loop:

```sh
echo '{"kind":"type","name":"Agent",...}' | ./entity
```

## Scope

In scope:

- `@name` and `@name(args...)` on a type declaration, on a field within one, on
  a function declaration, and on a function parameter.
- Arguments limited to literals: strings, integers, floats, booleans. Not
  expressions — a decorator argument is metadata, not code.
- A declaration description as JSON, versioned, covering the shapes above.
- Resolution of a decorator name to an executable.
- Splicing returned source into the program before checking.
- A decorator that fails — non-zero exit, unparseable output, or output that
  does not compile — reports as a located error at the decorator's own line.
- Caching: a decorator runs again only when its input or its binary changes.

Out of scope:

- Decorators that modify the declaration they are attached to. A decorator adds
  declarations; the annotated type is emitted unchanged. Rewriting would need
  the compiler to re-check a mutated AST, and every question about ordering and
  conflicts that follows.
- Decorators on statements, expressions, or class members other than through
  the type form.
- Hygiene beyond a naming convention. Generated names live in the flat
  namespace like everything else; a decorator that emits `agentRepository`
  collides with a hand-written one, and says so through the ordinary duplicate
  diagnostic.
- Running decorators for `lumen check` in a fast path. Check runs them too, or
  the two commands disagree about what a program contains.

## Design

### D1 — syntax

`@` followed by an identifier, optionally followed by a parenthesised argument
list of literals. One or more may precede a type declaration, a field, a
function declaration, or a parameter. The parser attaches them to the
declaration; the AST carries a `decorators: []Decorator` on each.

A decorator on a field is not otherwise meaningful — fields have no independent
existence — so it is carried purely as data for the enclosing declaration's
decorator to read.

### D2 — the description

One JSON document per decorated declaration, on the program's stdin:

```
{ "protocol": 1,
  "kind": "type" | "function",
  "name": string,
  "args": [literal],
  "file": string, "line": int,
  "fields":  [ { "name", "type", "decorators": [{ "name", "args" }] } ],   // kind=type
  "params":  [ { "name", "type", "decorators": [...] } ],                  // kind=function
  "returns": string                                                        // kind=function
}
```

`type` is the annotation as written, not a resolved type: a decorator that
cares about `string[]` versus `string` reads the text. The compiler has not
necessarily checked the declaration when a decorator runs — it cannot, since
the program is incomplete until generation finishes.

`protocol` is present so a decorator can refuse a version it does not know.

### D3 — resolution

A decorator name resolves to an executable through a manifest beside the
program, `lumen.decorators.json`:

```json
{ "entity": "./tools/entity", "tool": "./tools/tool" }
```

A name with no entry is an error naming the manifest. Paths are relative to the
manifest, and are executables — building them is the project's business, the
same way `// @link ./shim.o` expects an object file to exist.

The manifest is deliberately explicit rather than a search path: a compiler
that runs programs found by convention is a compiler that runs programs you did
not mean to run.

### D4 — splicing

Output is appended to the program as though written at the end of the file that
declared the decorator, so imports in scope there are in scope for it. It is
then parsed and checked with everything else — a decorator cannot emit
something that skips the checker.

Ordering: decorators run in source order, and all output is appended in that
order. A decorator cannot see another's output; they receive declarations, not
the program.

### D5 — failure

Three ways to fail, all reported at the decorator's line, all naming the
decorator:

- the program exits non-zero — its stderr is the message;
- its output does not parse — the parse error, with the generated source
  attributed to the decorator rather than to a file the user wrote;
- its output parses but does not check — likewise.

The third is the one that decides whether this is usable. An error inside
generated code that points at a line the user cannot see is the failure mode
that makes code generation hated, and specs 451 through 453 each hit a version
of it in this compiler already.

### D6 — caching

A decorator's output is cached by the hash of its input JSON and the binary's
modification time. A build that changes neither reuses the output, so
decorators cost nothing on an unchanged rebuild.

## Success Criteria

1. `@entity("agents")` on a type, resolving to a program that echoes a
   function, produces a program in which that function is callable.
2. Field decorators reach the description, with their arguments, in order.
3. A decorator on a function receives its parameters and return type.
4. Two decorators on one declaration both run, in source order.
5. A decorator that exits non-zero fails the compile with its stderr, at the
   decorator's line.
6. A decorator whose output does not compile fails with the error attributed
   to the decorator, not to a phantom line of the user's file.
7. An unknown decorator name names the manifest and the missing key.
8. A second compile with nothing changed runs no decorator.
9. The std-contrib `plume` package's mapping is generated from a decorated
   type, and its tests pass against the generated repository.
10. `zig build test` passes; `zig build conformance` adds no new failures
    against the 193-passed / 50-failed baseline.

## Risks

- **This is the largest feature in the language.** It adds a phase — parse,
  *generate*, check, emit — and every later feature has to consider it. The
  scope above is deliberately the minimum that is useful: no AST rewriting, no
  hygiene, no macro-defining-macros.
- **Bootstrapping.** A decorator is a Lumen program, so building a project that
  uses decorators means building its decorators first. This spec does not solve
  build ordering; the manifest points at an executable and expects it to exist.
  A project with a decorator that must itself be compiled needs two passes, by
  hand, until something builds them.
- **Error attribution is the whole battle.** D5's third case decides whether
  people use this or route around it. It needs the generated source retained
  and addressable, which the diagnostic machinery does not do today — it maps
  lines back to user files through `g_line_map`, and generated code has no user
  file to map to.
- **A decorator can do anything a program can.** It runs at compile time with
  the compiler's privileges: read files, make requests, write anywhere. That is
  true of every macro system, and the manifest at least makes what runs
  explicit rather than implicit.
- **Compile time.** Each decorator is a process spawn. The cache makes the
  steady state free, but a cold build pays per decorated declaration.

## Notes

The value is not shorter source. It is that a declaration stops being restated:
today a `plume` mapping repeats every field of the record it maps, and nothing
but attention keeps the two in step. After this, the record is the single
statement of the shape, and the mapping is derived from it.

The same shape is waiting in the `ai` package, where a tool's parameter schema
is written out beside the function it describes, and in any serializer,
route table, or CLI parser written later.
