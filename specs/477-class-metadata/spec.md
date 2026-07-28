# Spec 477: what the compiler knows about a class, as a value

## Goal

A decorated controller is handed straight to the server:

```ts
let problem = listen(8100, [
  mount(new AgentApi(db, master)),
  mount(new ModelApi(db, master)),
  mount(new ThreadApi(db, master)),
]);
```

No route table walked by hand, no per-controller handler-name prefix invented
so `AgentApi.list` and `ModelApi.list` do not collide, no `Map<string, Handler>`
written out one entry per route.

## Why it does not work today

`@controller("/agents")` (spec 455, std-contrib `packages/rest`) leaves a
constant behind:

```ts
let controllerAgentApi: Route[] = [
  { method: "GET", pattern: "/agents", handler: "list" }, …
];
```

and there it stops. A `Route` names its handler; it cannot hold one, because a
decorator's value travels back as JSON and JSON cannot carry a function. So
every program that uses a controller has to close the gap itself, and
`packages/agents/api.ts` closed it with ~400 lines in `main()`:

1. fifteen loops copying each `controller*` array into one table, each
   rewriting `r.handler` to `"h" + r.handler`, `"d" + r.handler`, `"ks" +
   r.handler` — prefixes invented at the call site, by hand, so that two
   controllers with a `list` do not overwrite one another;
2. seventy `bound.set("hlist", (req) => { try { … } catch { … } })` lambdas;
3. `serve(8100, table, bound)`.

Three things were wrong with it, in increasing order of seriousness:

- It is longer than the API it serves.
- The prefixes are a namespace maintained by attention. Nothing checks that
  `"a"` for `ArtifactApi` and `"a"` for `PreviewApi` do not collide; the file
  has a comment explaining why that particular collision happens to be safe.
- Delete one `try/catch` and the process dies on a bad request. That is not
  hypothetical: `JSON.parse<T>` throws when a PUT body omits a field the record
  declares, and one such request took the whole API down. The `try` inside
  `serve` does not help — a handler arrives as a function value, spec 245's
  fixpoint pass cannot see through one, so the callee is emitted as
  non-throwing and the throw panics before any `try` upstream runs.

## Why the obvious seams lose

**Make the decorator emit a bind table too.** A binding is `(req) =>
instance.list(req)`. The decorator runs in its own process, before the class
exists as anything but a description, and returns JSON. It cannot name the
instance — the instance does not exist until `main` runs — and it cannot return
a function. Spec 455 §"What a decorator is" also rules out the escape hatch
that would make it possible: a decorator returns a value, never source text.

**Make `serve` accept objects.** `serve` is ordinary code in a std-contrib
package. Given `new AgentApi(db)` it can no more call `list` by name than the
decorator could: there is no runtime type information in a Lumen binary and
there will not be. It would have to be a compiler builtin that knew `Route`,
`Handler` and `Reply` — HTTP vocabulary inside the compiler, which is exactly
what spec 455 was built to avoid ("the compiler knows the syntax and the
protocol, never the vocabulary").

**Fix throw-propagation through function values.** Worth doing on its own
merits, and it would let one `try` inside `serve` guard every handler. It does
not address the other two problems at all — the table walking and the invented
prefixes are still there — and it is a change to the calling convention of
every function value in the language. Out of scope here; this spec removes the
need for it along this path by never routing a throw through a function value
in the first place.

## The seam

Three things about a class are known to the compiler and unreachable from the
program: its **name**, the **value a decorator produced for it**, and its
**methods, callable by a name chosen at run time**. Expose exactly those three,
under a `Class` namespace, and the whole mechanism is ordinary library code.

```ts
Class.nameOf(c)                     // "AgentApi"
Class.decorator(c, "controller")    // the Route[] @controller left behind
Class.invoke(c, handler, req)       // c.list(req), chosen by the string
```

None of the three survives into the emitter. Each is resolved while checking
and rewritten in place:

| written | becomes |
| --- | --- |
| `Class.nameOf(c)` | the string literal `"AgentApi"` |
| `Class.decorator(c, "controller")` | a reference to `controllerAgentApi` |
| `Class.invoke(c, h, req)` | a call to a generated dispatcher function |

So there is no new runtime, no reflection, no metadata section in the binary —
the same trade spec 455 made, one level down.

### `Class.invoke`

`Class.invoke(receiver, name, a0, …, aN)` calls the method of `receiver`'s
class named by `name`. The compiler generates, once per (class, argument
types), a dispatcher:

```ts
function __dispatch_AgentApi_1(__self: AgentApi, __handler: string, __a0: Request): Reply {
  if (__handler == "list")   { return __self.list(__a0); }
  if (__handler == "find")   { return __self.find(__a0); }
  …
  throw new Error("AgentApi has no handler named \"" + __handler + "\"");
}
```

and rewrites the call to name it. Candidates are the public, non-static,
non-async, non-accessor methods of the class and its bases whose parameter
types are exactly the argument types given. They must agree on a return type;
if they do not, that is an error naming the two that disagree, at the
`Class.invoke` site.

**This is what keeps the `try/catch`.** Every branch is a *direct* method call,
which is the case spec 245 and spec 247 already propagate through. A throw
inside `list` leaves the dispatcher as an error, leaves `Class.invoke` as an
error, and is caught by a `try` around it — in the framework, once, for every
handler of every controller. Nothing at the call site can opt out of it,
because nothing at the call site names a handler.

An unknown name throws rather than returning a sentinel, so the framework's
existing `catch` reports it the same way it reports everything else.

### `Class.decorator`

`Class.decorator(receiver, "controller")` is the constant `@controller` left
beside the class — `controllerAgentApi`, by spec 455 D4's naming rule. Its type
is the constant's own declared type, so `mount` below gets a `Route[]` and not
an `any`. A class carrying no such decorator is an error naming the class and
the decorator.

The point of it is that the *call site* never writes the constant's name. Only
`mount<T>` does, once, generically.

### `Class.nameOf`

The class's declared name, as a string. It is what lets the framework qualify
handler names by controller without the program choosing prefixes — the failure
this whole spec starts from.

### Generics carry it

None of the three is useful at a fixed type; the framework has to say it once
for every controller. They work inside a generic function, because
specialization substitutes the type parameter before the body is checked:

```ts
export function mount<T>(c: T): Mount {
  return {
    controller: Class.nameOf(c),
    routes: Class.decorator(c, "controller"),
    call: (handler: string, req: Request) => {
      try { return Class.invoke(c, handler, req); }
      catch (e) { return badRequest("the request could not be handled: " + e.message); }
    },
  };
}
```

`mount(new AgentApi(db))` specializes that at `T = AgentApi`, and the closure
it returns is the only thing that ever calls a handler.

## What this makes impossible

- **Two controllers with the same handler name cannot collide.** Each mount
  keeps its own routes and its own dispatcher, and a handler name is only ever
  looked up in the controller it came from. There is no shared keyspace to
  collide in, so there is nothing for a user to get wrong. Where a name has to
  be shown — the startup route log, the "two controllers serve the same path"
  check — the framework writes `AgentApi.list`, from `Class.nameOf`, never from
  a prefix the program chose.
- **A route with no handler.** It used to be a startup check (`bindingProblem`)
  because the bindings were written by hand. Now the routes come from the
  decorator, which derived them from the class's own methods, and the dispatch
  comes from the same class. They cannot disagree.
- **An unguarded handler.** There is one path from a request to a method and it
  goes through `mount`'s `try`.

## Scope

In scope:

- `Class.nameOf`, `Class.decorator`, `Class.invoke`, resolved at check time and
  rewritten in place, inside generic and non-generic code alike.
- Diagnostics at the call site for: a receiver that is not a class instance, a
  decorator name that is not a string literal, a class carrying no such
  decorator, no method matching the argument types, and candidate methods that
  disagree about their return type.
- `packages/rest`: `Mount`, `mount<T>`, `mountedRoutes`, `mountProblem`,
  `dispatchMounted` and `listen(port, mounts)`. A separate name from `serve`
  because the language has no overloading and the three-argument `serve(port,
  table, handlers)` is untouched and keeps working — spec 455's own examples and
  `packages/rest`'s own tests are the proof.
- One thing found on the way, fixed because it is the same bug: `cloneExpr`
  shared an arrow's **block body** between specializations of a generic
  function instead of cloning it. So a `let x: T` inside an arrow never had `T`
  substituted, and anything the checker rewrites in place was rewritten once —
  for whichever specialization reached it first. Two controllers mounted by one
  generic `mount<T>` is exactly that case.

Out of scope:

- Reading fields by name, or setting anything. `Class.invoke` calls; it does not
  make a class into a dictionary.
- Static methods, constructors, accessors, `async` methods.
- Anything at run time. A `Class.*` call whose receiver's class is not known
  statically is an error, not a lookup.

## Success criteria

1. Two controllers each with a `list`, mounted together, both answer, and
   neither name is written at the call site.
2. A handler that throws answers 400 and the process is still serving.
3. A route with a path parameter reaches its handler with the parameter bound.
4. `Class.invoke` with a name no method has throws, and the framework's `catch`
   turns it into a reply.
5. The three-argument `serve` still works, and `packages/rest`'s existing
   tests and examples are unchanged.
6. `zig build test` passes; `zig build conformance` adds no new failures.
