# Spec 500: `JSON.parseOpen<T>()`

## Goal

```ts
type Hello = { name: string, build: string };

JSON.parse<Hello>(text);      // refuses a field Hello does not declare
JSON.parseOpen<Hello>(text);  // reads the fields it knows, ignores the rest
```

## Why

`JSON.parse<T>` refuses a payload carrying a member `T` does not declare, and
that is the right default for a request body: it catches a typo and a stray
field, which is most of what a `rest` route's single `try` is buying.

It is the wrong default for a payload written by something that is not this
build of this program. A sender that adds a field breaks every receiver
compiled against the older type, totally and immediately — joule-sh/code #195
was exactly that: adding `build` to a `session.hello` frame made every older
client unable to decode any hello at all. The fix there was to abandon the
typed parser for frames and hand-scan fields, which costs the validation the
parser was doing: once a body is read a field at a time, the type is not
consulted and nothing is checked.

The same shape appears whenever a model writes the JSON. A model told to emit
`{"stages":[...]}` will sometimes add a field nobody asked for.

## Semantics

`JSON.parseOpen<T>(text)` is `JSON.parse<T>(text)` in every respect but one: a
member the type does not declare is ignored instead of refused.

Everything else is unchanged, and deliberately so — a missing required field
is still refused and still named, a field of the wrong type is still refused
and still named, and malformed JSON still throws. Openness is about members
`T` never mentioned, not about relaxing what `T` does say.

## Success Criteria

- **SC-001**: `JSON.parseOpen<T>` reads a payload carrying an undeclared field.
- **SC-002**: `JSON.parse<T>` still refuses it, with the same message as before.
- **SC-003**: `JSON.parseOpen<T>` still refuses a payload missing a required
  field, and still names it.
- **SC-004**: a program that declares its own `open` still compiles — nothing
  the generated parser introduces may take an ordinary name.
- **SC-005**: `zig build` and `zig build test` stay green.
