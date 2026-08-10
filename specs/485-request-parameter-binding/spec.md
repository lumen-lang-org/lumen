# Spec 485: a handler's parameters are bound from the request

## Goal

```ts
@controller("/things")
class ThingApi {
  @get("/:id")
  find(@PathVariable("id") id: string,
       @RequestParam("limit", "10") limit: int,
       @RequestHeader("x-user") who: string): Reply { … }

  @put("/:id")
  save(@RequestBody ask: Ask): Reply { … }
}
```

Every one of those annotations already parsed and already reached the compiler
with the parameter's name, its type and the annotation's arguments. What did not
exist was anything that read them: `mount` gathered only methods whose parameter
list was exactly `(Request)`, so a handler written this way was never dispatched.

## The rule

> A method whose every parameter carries a request-binding annotation is
> dispatchable. The generated dispatcher binds each parameter out of the request
> instead of passing the request through. A method taking `(Request)` is
> unchanged, and the two forms coexist in one controller.

| annotation | binds to |
|---|---|
| `@PathVariable("id")` | `param(req, "id")` |
| `@RequestParam("limit", "10")` | `queryParam(req, "limit", "10")` |
| `@RequestHeader("x-user")` | `header(req, "x-user")` |
| `@RequestBody` | `JSON.parse<T>(req.body)`, or `req.body` when the parameter is a string |

`@path`, `@query`, `@header` and `@body` are accepted as the short spellings.

A parameter typed `int` gets the conversion written for it: `@RequestParam("limit",
"10") limit: int` binds `parseInt(queryParam(req, "limit", "10"), 10) ?? 0`. The
compiler knows the type at that point, so the conversion is decided while
compiling rather than guessed at run time. The annotation's first argument names
the path segment, query key or header; omit it and the parameter's own name is
used.

## Why the body's refusal is the point

`JSON.parse<T>` refuses a body that omits a declared field, sends one the type
does not name, or sends the wrong kind of value, and since spec 483 it names the
field. That throw happens inside the dispatcher, which `mount` already wraps in
the one `try` that turns a handler's throw into a 400.

So a body that does not fit its type **never reaches the handler**, and the
handler contains no validation at all. That is asserted rather than described:
`binding.test.ts` PUTs `{"name":"box"}` at a handler wanting `{name, size}` and
checks for a 400 naming `size`, and separately checks a well-formed body arrives
as a typed value.

## How

`generateDispatcher` in `src/lumen_check_meta.zig` writes the dispatcher as
ordinary Lumen source, so binding is a matter of writing the call the handler
would otherwise have written by hand:

```ts
if (__handler == "find") {
  return __self.find(param(__a0, "id"),
                     parseInt(queryParam(__a0, "limit", "10"), 10) ?? 0,
                     header(__a0, "x-user"));
}
```

`param`, `queryParam` and `header` resolve because every module is flattened into
one program and `rest/server.ts` declares them there; the body's type resolves
for the same reason, wherever the controller declared it.

Two details worth stating, because both were bugs first. The arity check
`m.params.len != arg_types.len` used to skip a method before the binding path
could see it, so a three-parameter handler was silently not a candidate. And the
dispatcher's own signature is built from the dispatched argument types rather
than from the method's parameters — a bound method's parameters are what it
wants, while the dispatcher is always called with the request.

## What this does not do

It does not validate values. `@Valid` is not implemented here; shape is the
type's business and length, range and membership belong to `packages/validation`,
which dispatch can call once the rules are reachable from a mount.
