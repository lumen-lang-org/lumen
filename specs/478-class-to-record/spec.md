# Spec 478: a class instance where a record is expected

## Goal

```ts
listen(8100, [
  new AgentApi(db, master),
  new ProviderApi(db, master),
  new ThreadApi(db, master),
]);
```

Spec 477 got the call site down to this, except for one word per line:

```ts
listen(8100, [
  mount(new AgentApi(db, master)),
  mount(new ProviderApi(db, master)),
  mount(new ThreadApi(db, master)),
]);
```

`mount` carries no information. It is the instance, boxed. Fifteen of them is
fifteen instances of a word that says nothing about the program.

## Why the word is there

`listen` takes `Mount[]`. `[new AgentApi(db), new ProviderApi(db)]` is not a
`Mount[]` and is not any array: arrays are homogeneous, there are no trait
objects, and two classes have no common type. So the erasure to one record has
to happen per element, at the site, and until now the program had to write it.

The erasure is necessary. Typing it is not.

## The rule

> A value whose type is a class instance, appearing where a **named record
> type** is expected, goes through the one generic function that makes that
> record: a declaration `f<T>(c: T): R` taking a single parameter of its own
> type parameter. If the program declares no such function, the ordinary type
> mismatch stands. If it declares more than one, that is an error naming both.

Applied elementwise by the existing array path, so `[new AgentApi(db), …]` in a
`Mount[]` position becomes `[mount(new AgentApi(db)), …]` before anything else
sees it.

**Nothing that compiles today changes meaning.** A class instance is not
assignable to a record and never has been — every site this rule fires on is a
site that is an `E_TYPE_MISMATCH` today. The rule can only turn errors into
programs, never one program into a different one.

**Generic on purpose.** A converter written for one class — `f(c: Agent): Mount`
— says nothing about any other class and is not reached for one. Only a
function that claims to convert *any* `T` is treated as the way to make an `R`.

**One or none.** Two converters to the same record is an error naming both,
because which was meant is not the compiler's to guess.

## The seam, and the one that lost

The alternative on the table was to special-case `listen` by name in the
compiler, the way `serve` already is at `lumen_emit.zig:423` and
`lumen_check_expr.zig:2064` — narrower, and honest about being a special case.

It does not work, for a reason specific to those two precedents. `serve` and
`httpGet` are *compiler builtins*, and the guard on both is
`self.funcs.get("serve") == null` — **a user declaration wins**, and the special
case switches off. `listen` is the opposite: it is an ordinary exported function
in a std-contrib package, so the compiler would have to fire *because* the user
declared it, and fire on the name alone. That inverts the existing rule rather
than following it, and it means:

- any program with its own `listen` gets its array elements silently rewritten;
- the compiler learns `Mount`, `listen` and `mount` — HTTP vocabulary from one
  package, which is exactly what spec 455 built the decorator protocol to
  avoid ("the compiler knows the syntax and the protocol, never the
  vocabulary");
- the next framework that wants this — a CLI command table, an MCP tool
  registry, a job registry — needs another compiler patch, and its own name
  hardcoded beside `listen`.

The rule above is more general, but it is not "an implicit conversion that
could fire anywhere": it fires only where a class meets a record, which is
already an error, and only when the program has said, by declaring exactly one
`f<T>(c: T): R`, how that record is made. The blast radius is the set of
programs that do not compile.

The third option — infer a conversion between any two types by searching for a
function of the right shape — is the one worth refusing. It would fire in
positions that compile today and change what they mean.

## Diagnostics

A class with no `@controller` reaches `mount<T>`, whose `Class.decorator` fails.
The message names the class, and it is reported at the call that named it, not
at the library line that wrote `Class.decorator` for every class there will ever
be:

```
api.ts:17:7: error: `NotAController` carries no `@controller`, so there is no
             `controllerNotAController` to read
  17 |   let problem = listen(8123, [new AgentApi(), new NotAController()]);
     |       ^~~~~~~
```

That attribution is its own small change: a generated specialization now records
the line and column of the call that asked for it (`FunctionDecl.spec_site`),
and a diagnostic raised while checking a specialized body uses it.

## Scope

In scope: the conversion rule, the ambiguity error, the call-site attribution
for diagnostics from a specialized generic.

Out of scope:

- Conversion to anything but a named record — no class-to-class, no
  class-to-scalar, no record-to-class.
- Non-generic converters.
- A converter chosen by anything other than "there is exactly one".
- Dependency injection of any kind. `new AgentApi(db, master)` names what it is
  given, where a reader can see it. Nothing here constructs anything, and
  nothing scans for controllers.

## Success criteria

1. `listen(port, [new A(db), new B(db)])` compiles and serves both.
2. `listen(port, [mount(new A(db))])` still compiles — `mount` is exported and
   the record is still writable by hand.
3. A class in the list without `@controller` fails to compile, naming the class,
   at the call site.
4. Two generic converters to one record is an error naming both.
5. `serve(port, table, handlers)` is untouched.
6. `zig build conformance` adds no new failures.
