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

A decorator is a Lumen function the compiler runs while compiling. It receives
a description of the declaration it was attached to, and returns **a value**.
The compiler emits that value as a constant beside the declaration.

It does not return source text. A decorator that emits a string of Lumen is
untyped at the point it matters most — the compiler cannot check what it
returns until after it has been parsed, its errors point at lines nobody
wrote, and every decorator reimplements string-building for the same handful
of shapes. Returning a value keeps the whole path typed: the decorator's
return type is declared, the checker verifies it, and the constant the
compiler emits has that type.

```ts
@entity("agents")
class Agent {
  @id @column("id", "text")
  id: string;

  @column("agent_name", "text")
  agentName: string;
}
```

Decorators attach to classes and their members, as they do in TypeScript, and
not to a type alias — `tsc` rejects a decorated `type`, and there is no reason
to diverge from that placement. This makes spec 456 a prerequisite: an entity
is a class, and the mapping generated for it moves data as JSON, which a class
instance cannot do today.

`@entity` is not known to the compiler. It is an imported function, and it
receives:

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

and returns a `DbRepository` — plume's own type, which the decorator module
imports like any other:

```ts
import { DbRepository, field, repository } from "plume";

export function entity(d: Description): DbRepository {
  let fields: DbField[] = [];
  let i: int = 0;
  while (i < d.fields.length) {
    let col = argOf(d.fields[i], "column", 0);
    let sqlType = argOf(d.fields[i], "column", 1);
    fields.push(field(d.fields[i].name, col, sqlType));
    i = i + 1;
  }
  return repository(d.args[0], keyField(d), keyColumn(d), fields);
}
```

The compiler emits the returned value as a constant named for the decorator
and the declaration it was attached to:

```ts
let entityAgent: DbRepository = { table: "agents", idField: "id", ... };
```

so the program uses it directly:

```ts
persist(database, entityAgent, JSON.stringify(a));
```

Anyone can write one. The compiler knows the syntax and the protocol, never the
vocabulary — there is no built-in `@entity`, `@tool` or `@route`, and adding
one requires no compiler change.

## Why the compiler builds and runs it

There is no interpreter — that path was deliberately dropped, and the generated
Zig is the product. So user code can only run at compile time if it is compiled
first. That is staged compilation, and the compiler is already the thing that
compiles: resolving a decorator is recursion into its own entry point, not new
machinery.

The decorator itself stays an ordinary function of an ordinary type, so it is
tested by calling it:

```ts
test("entity maps a field to its column", () => {
  let out = entity(descriptionFixture());
  expect(out.indexOf("field(\"agentName\", \"agent_name\", \"text\")") >= 0);
});
```

## Scope

In scope:

- `@name` and `@name(args...)` on a class declaration, on a class member, on a
  function declaration, and on a function parameter.
- Arguments limited to literals: strings, integers, floats, booleans. Not
  expressions — a decorator argument is metadata, not code.
- A declaration description as JSON, versioned, covering the shapes above.
- Resolution of a decorator name through an ordinary import, and compilation
  of the module it names.
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

`Description` is a type the compiler provides, mirroring the JSON it also
writes for `lumen describe`:

```
{ "protocol": 1,
  "kind": "class" | "function",
  "name": string,
  "args": [literal],
  "file": string, "line": int,
  "fields":  [ { "name", "type", "decorators": [{ "name", "args" }] } ],   // kind=class
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

A decorator is an exported function, imported like anything else:

```ts
import { entity } from "./tools/entity.ts";

@entity("agents")
type Agent = { ... };
```

There is no manifest and no separate build step. The compiler resolves `@entity`
to the imported binding, finds the module it came from, compiles that module,
and runs it.

The exported function takes one `Description` and returns anything JSON can
carry — a record, a class instance, an array of either, or a scalar. The
checker enforces the parameter and rejects a return type it cannot serialise,
naming the offending field:

```ts
export function entity(d: Description): DbRepository
```

`Description` is a type the compiler provides. A function in decorator position
taking anything else is an error naming the expected signature. The return type
is the decorator's own choice — that is what makes the vocabulary open.

This makes a decorator a pure function of its description, which has three
consequences worth the design:

- It is unit-testable with `lumen test`, by calling it — no compiler, no pipes,
  no fixtures on disk.
- It cannot read files, make requests, or exit; a decorator that wants to do
  those things is writing a build step, not a decorator.
- Nothing needs stdin, which the standard library does not offer today.

The module is compiled standalone rather than inlined into the importing
program: a decorator import contributes the binding and nothing else, so a
decorator's helpers do not land in the namespace of every program that uses it.
The compiler generates the entry point that reads the description, calls the
function, and prints what it returns.

A cycle — a decorator module that imports, directly or otherwise, the file it
decorates — is an error naming both files. Left alone it would be an infinite
regress: the file cannot be compiled until the decorator runs, and the
decorator cannot be compiled until the file is.

### D4 — splicing

The compiler runs the decorator, captures its return value as JSON, and emits
a constant of the decorator's declared return type, initialised to that value.
The name is `<decorator><Declaration>` — `@entity` on `Agent` gives
`entityAgent` — which is deterministic, needs no hygiene rules, and collides
through the ordinary duplicate-binding diagnostic if a hand-written binding
already has that name.

The constant is emitted as a literal, not as a parse at startup: the compiler
has the JSON and the type, and turning the two into a record literal is the
same walk the JSON runtime already does. A program pays nothing at runtime for
a decorator.

The constant is declared in the file that carried the decorator, directly after
the declaration it belongs to: the file's imports are above it, so the return
type's own import is in scope, and everything written below can use it. The end
of the file would be too late — a top-level binding is not in scope before its
own line, so a constant appended after the program's last statement is one
nothing can name. It is then checked with everything else — a decorator's output
cannot skip the checker.

Ordering: decorators run in source order, each producing its own constant. A
decorator cannot see another's output; they receive declarations, not the
program.

### D5 — failure

Three ways to fail, all reported at the decorator's line, all naming the
decorator:

- the decorator module does not compile — reported as an error in that module,
  since it is the user's own code and has its own file and lines;
- the decorator exits non-zero when run — its stderr is the message, at the
  decorator's line;
- the value it returns does not fit its declared return type — which the
  checker catches at the constant, naming the field.

Returning a value rather than source is what makes the third case ordinary. A
decorator that emitted text could produce something that parses into anything,
and an error inside it would point at a line the user cannot see — the failure
mode that makes code generation hated, and one specs 451 through 453 each hit
a version of in this compiler already. Here the generated constant has a
declared type and a known shape, so a mismatch is reported against the
decorator's own signature.

### D6 — caching

A decorator's output is cached by the hash of its input JSON and the binary's
modification time. A build that changes neither reuses the output, so
decorators cost nothing on an unchanged rebuild.

## Success Criteria

1. `@entity("agents")` on a class, resolving to a decorator that returns a
   record, produces a program in which the generated constant holds that
   record and is usable.
2. Field decorators reach the description, with their arguments, in order.
3. A decorator on a function receives its parameters and return type.
4. Two decorators on one declaration both run, in source order.
5. A decorator that exits non-zero fails the compile with its stderr, at the
   decorator's line.
6. A decorator whose return type cannot be serialised fails at its own
   signature, naming the field, not at a phantom line of the user's file.
7. An unknown decorator name names the manifest and the missing key.
8. A second compile with nothing changed runs no decorator.
9. The std-contrib `plume` package's mapping is generated from a decorated
   class, and its tests pass against the generated repository — on all three
   databases.
10. `zig build test` passes; `zig build conformance` adds no new failures
    against the 193-passed / 50-failed baseline.

## Risks

- **This is the largest feature in the language.** It adds a phase — parse,
  *generate*, check, emit — and every later feature has to consider it. The
  scope above is deliberately the minimum that is useful: no AST rewriting, no
  hygiene, no macro-defining-macros.
- **The compiler compiles during compilation.** Resolving a decorator means
  building its module, which is recursion into the compiler's own entry point.
  That is not new machinery, but it is new control flow: a failure inside it
  must report as a failure of the decorator, and a cycle must be caught rather
  than recursing until the stack ends.
- **Error attribution is the whole battle.** D5's third case decides whether
  people use this or route around it. It needs the generated source retained
  and addressable, which the diagnostic machinery does not do today — it maps
  lines back to user files through `g_line_map`, and generated code has no user
  file to map to.
- **A decorator runs at compile time, with whatever the language allows.**
  Constraining it to a pure function of a description keeps it from reading
  files or making requests by construction, rather than by policy — the
  signature has nowhere to put a side effect. That is a stronger guarantee than
  most macro systems offer, and it is free.
- **Compile time.** Each decorator means compiling a module and running it. The
  cache makes the steady state free, but a cold build pays a full compile per
  decorator module — the cost the manifest-and-prebuilt-binary alternative was
  trading against, and the reason the cache is in the first useful slice rather
  than a later one.

## Notes

The value is not shorter source. It is that a declaration stops being restated:
today a `plume` mapping repeats every field of the record it maps, and nothing
but attention keeps the two in step. After this, the record is the single
statement of the shape, and the mapping is derived from it.

The same shape is waiting in the `ai` package, where a tool's parameter schema
is written out beside the function it describes, and in any serializer,
route table, or CLI parser written later.
