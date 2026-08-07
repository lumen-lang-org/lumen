# Spec 481: an optional field may be absent, not merely null

## What was true

```ts
type WfNode = {
  id: string,
  source?: string,   // added later
};

JSON.parse<WfNode>("{\"id\":\"a\"}")   // throws: invalid JSON (MissingField)
```

The mark bought the right to write `null`. It did not buy the right to leave
the field out — which is the only thing anybody adds it for.

A record lowers to a Zig struct, and `JSON.parse<T>` is `std.json`'s own
reflection over that struct. `std.json` requires every field that has no
default. An optional field was emitted as `source: ?[]const u8,` — a type that
can hold null, with no default — so a document omitting it was refused exactly
as if the field had never been marked.

## Why it mattered enough to be a spec

This is the failure mode of adding a field to something already stored, and it
is silent in the worst way: the type declaration says the old documents are
fine, the compiler agrees, and then every row written before today stops
loading. A workflow graph saved last week answered "that is not a workflow
graph". The fix looked like it worked, because the editor that saved a graph
started writing the new field — so only the documents nobody had reopened were
broken, which is the set nobody looks at.

The wrong lesson was available and nearly taken twice: rewrite the stored rows,
or drop the `?`. Both leave the language unable to do the thing the mark is
for.

## What is true now

An optional field is emitted with `= null`. Absent parses to null; present
parses to the value; nothing else changes.

```ts
type Node = { id: string, source?: string, cases?: string };

JSON.parse<Node>("{\"id\":\"a\"}")                    // source and cases null
JSON.parse<Node>("{\"id\":\"a\",\"source\":\"x\"}")   // cases null
```

The rule this states, in one line: **a field added to a stored document has to
be optional, and optional has to mean absent-able, or the two halves of that
sentence do not meet.**

## Not in scope

Required fields keep no default: a document missing one is still an error, and
should be. Silence about a field the type says is always there is how a
malformed row travels on as a struct full of zeroes, which spec 252 already
refused to allow.
