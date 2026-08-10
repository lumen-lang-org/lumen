# Spec 483: a failed JSON.parse names the field

## Goal

```ts
type Ask = { siteKey: string, secret: string, enabled: bool };

JSON.parse<Ask>("{\"siteKey\":\"k\",\"enabled\":true}");
```

Before:

```
JSON.parse: invalid JSON (MissingField)
```

After:

```
JSON.parse: the field "secret" is required and was not sent
```

## Why it matters more than it looks

`JSON.parse<T>` is already a validator. It refuses a body that omits a declared
field, sends a field of the wrong type, or sends one the type does not name —
and in a `rest` service `mount`'s single `try` turns that throw into a 400. So
the shape of every request body is checked by the compiler-generated parser and
nothing else has to.

What the caller got back was `MissingField`. Which field, out of the eleven the
record declares, was not said. A client integrating against the API learns only
that it is wrong, and the person debugging it reads the type and guesses.

That silence had a second cost: it pushed field checking back into the handlers.
A route that cannot rely on a useful refusal writes its own — `jsonText(body,
"siteKey")` then a hand-rolled test for empty — and once the body is read a
field at a time, the type is not consulted at all and nothing is validated.
`packages/agents` does this in most of its 215 routes.

## The rule

> When `JSON.parse<T>` fails and `T` is a record, the message names the field
> and what was wrong with it. A field that is optional or has a default may be
> absent. If no single field explains the failure, the previous message stands.

Three cases, in the order they are looked for:

| what happened | message |
|---|---|
| a required field was not sent | `the field "secret" is required and was not sent` |
| a field the type does not declare was sent | `the field "typo" is not one this accepts` |
| a field was sent with the wrong kind of value | `the field "enabled" wants a true or false` |

`wants` is written in the language of the wire, not of the compiler: `a string`,
`a whole number`, `a number`, `a true or false`. A client author reading a 400
is not reading Zig.

## How

`__jsonBlame` in `src/lumen_runtime_net.zig`, called only on the failure path, so
a body that parses pays nothing. It re-reads the text as a dynamic
`std.json.Value` and compares it against `@typeInfo(T).@"struct".fields`, which
the compiler already knows — the same information the generated parser was built
from.

Absence is only reported for fields that must be there: a field whose type is
optional, or which carries a default, may be omitted.

The old message is still the fallback. A body that is not an object, or is not
JSON at all, has no field to blame, and `invalid JSON (UnexpectedToken)` remains
the honest answer.

## What this does not do

It does not validate values, only shapes. `maxLength`, ranges, enum membership
and formats are not something a type expresses, so they stay where they are —
and a package for them is the natural next piece, now that the shape half is
answered properly.
