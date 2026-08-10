# Spec 480: running a command that cannot reach anything else

## What is true today

```
child_process.spawnSync(cmd: string, args: string[])
child_process.spawn(cmd: string, args: string[])   // a long-lived handle
```

Two arguments, and neither of them is a boundary. The child inherits the
parent's environment, its working directory, its file descriptors, its network
and its user. A Lumen program that runs `sed` also hands over every credential
in its environment, the whole filesystem the process can read, and the ability
to open a socket to anywhere.

That is fine for a build script someone runs on their own machine. It is not
fine for the case that has arrived: an agent server deciding to run a command
because a model asked it to, on a host that holds provider keys, where the
model's input includes retrieved documents and answers from other agents. The
package that would use this already says so about its neighbouring feature —
*"a reply is downstream of retrieved passages, tool results and delegated
answers, and the model echoing an injected block **is** the attack"*.

So the question this spec answers is not "can Lumen run a command" — it can —
but "can a Lumen program run a command it does not trust, and say exactly what
that command is allowed to touch".

## What other runtimes decided

**Deno** is the closest published answer and its shape is worth taking. It is
default-deny from its first release: no file, network or environment access
without an explicit grant, one narrow flag per capability — read, write, net,
env, run, ffi — with allow-lists inside a grant (`--allow-net=example.com`) and
`--deny-*` to carve exceptions out of a broader one. Every call is checked at
run time and refused with a distinct error rather than a silent zero.

The part worth learning from most is its own admission: **`--allow-run` escapes
the sandbox.** A spawned child is outside the permission system entirely, so
granting it is privilege escalation, and Deno's own documentation says so. A
capability system that stops at the process boundary is not one.

**Bubblewrap** is the other half. It builds the confinement out of the kernel's
own primitives — user, mount and PID namespaces plus seccomp — for unprivileged
callers, with a codebase small enough to audit, which is exactly the property
this needs and the reason not to reach for a container runtime. **Landlock**
covers the same ground from inside the process, and the two are designed to
stack. The distinction that decides which to use is a good one: bubblewrap for
a program you did not write, Landlock for one you control. A command a model
chose is emphatically the former.

## What this adds

One function, and a record that says what the child may do:

```ts
type Confinement = {
  // Directories the child may read. Nothing else is visible: not /etc, not the
  // parent's cwd, not the binary's own directory beyond what it needs to run.
  read: string[],
  // Directories the child may write. Empty means it writes nothing anywhere.
  write: string[],
  // The working directory, which must be inside `read` or `write`.
  cwd: string,
  // The environment, in full. Not "the parent's, minus some" — a subtraction
  // gets it wrong the day someone adds a variable, and the variable that gets
  // added is a credential.
  env: Map<string, string>,
  // Wall-clock milliseconds before the child is killed. There is no "no limit":
  // a command that never returns is the cheapest denial of service there is.
  timeoutMs: int,
  // Bytes of stdout and stderr kept. Beyond this the child is killed, because a
  // command that prints forever fills the disk of the host that spawned it.
  outputCap: int,
  // Whether the child may open a socket. A boolean and not an allow-list,
  // because a host allow-list is a DNS lookup away from being wrong, and
  // nothing that needs this feature yet needs the network at all.
  network: bool,
};

confinedSpawn(cmd: string, args: string[], within: Confinement): Confined
```

```ts
type Confined = {
  ok: bool,
  // Why it did not run, or why it was stopped: refused by the confinement,
  // timed out, killed at the output cap, or the exit status. Never empty when
  // `ok` is false.
  error: string,
  status: int,
  stdout: string,
  stderr: string,
  // What actually stopped it: "exit", "timeout", "output", "signal". A caller
  // that shows a user why a command failed needs this and not just a status.
  stopped: string,
};
```

There is no default `Confinement`. Records here have no field defaults, which
for once is the right shape rather than an obstacle: every caller states every
capability, and a capability that was never considered cannot be inherited by
accident.

## The rules

1. **Default deny, stated per call.** No ambient inheritance. The child gets the
   environment in `env` and nothing else; the mounts in `read` and `write` and
   nothing else; a socket only if `network` is true.
2. **The confinement is enforced by the kernel, not by the runtime.** Namespaces
   for the filesystem and the process tree, seccomp for the syscall surface. A
   check in Lumen would be advice; a mount namespace is a fact.
3. **A path that is not inside `read` or `write` does not exist to the child.**
   Not "is refused" — is absent, so a command that walks a directory finds
   nothing rather than finding a name it cannot open.
4. **Every stop reason is reported.** A timeout, an output cap and a non-zero
   exit are three different things and a caller that conflates them will retry
   the wrong one.
5. **The existing `spawnSync` and `spawn` keep working, unchanged.** This is a
   second door, not a replacement: a build script that wants the whole machine
   still says so, and now says so visibly.

## What it refuses to do

**No allow-list of hostnames.** `network: false` is the only supported answer
until something needs otherwise. A hostname allow-list is enforced at DNS
resolution, and the gap between resolving a name and connecting to an address is
where that control fails.

**No nested confinement.** A confined child may not itself confine — the
kernel primitives stack, but the reasoning does not: two layers of policy
written by two authors is how a hole appears that neither can see.

**No shell.** `cmd` is a binary and `args` are its arguments, passed as a vector.
There is no string to quote, so there is nothing to quote wrongly.

## Failure table

| what goes wrong | when it is caught |
|---|---|
| `cwd` outside `read` and `write` | refused before the child starts |
| a relative path in `read`, `write` or `cwd` | refused; a relative path means the caller's cwd, which the child does not have |
| `timeoutMs` of zero or less | refused; there is no unbounded run |
| the binary does not exist inside the mounts | refused, naming the path |
| the child writes outside `write` | the kernel refuses the write; the child sees an error, the parent sees the exit status |
| the child opens a socket with `network: false` | the kernel refuses; `stopped` is "exit" with the child's own failure |
| the child runs past `timeoutMs` | killed, `stopped` is "timeout" |
| the child prints past `outputCap` | killed, `stopped` is "output", and what was captured is kept |
| the child forks and the parent exits | the PID namespace takes the whole tree down with it |
| the platform cannot confine | **refused at the call, never silently unconfined** — the one rule that matters most |

That last row is the difference between this being a security feature and being
decoration. A runtime that quietly falls back to an ordinary spawn when the
kernel is too old, or on a platform without these primitives, is worse than one
that has no such function: the caller believes it is confined and behaves
accordingly.

## Where it does not apply

macOS and Windows have their own mechanisms and neither is namespaces. Until
those are written, `confinedSpawn` compiles everywhere and **refuses at run time
on any platform it cannot enforce**, with a sentence saying so. That is a real
limitation and stating it is better than a flag that means different things on
different machines.

## Conformance

- `confined-spawn.valid.reads-only-what-it-was-given` — a child that lists its
  root sees the mounts and nothing else.
- `confined-spawn.valid.write-outside-is-refused` — a write to a path outside
  `write` fails, and the parent sees the child's non-zero exit.
- `confined-spawn.valid.no-environment-leaks` — a child that prints its
  environment prints exactly what `env` carried, with a credential in the
  parent's environment absent from the child's.
- `confined-spawn.valid.timeout-kills-and-says-so` — a sleeping child is killed
  and `stopped` is "timeout".
- `confined-spawn.valid.output-cap-kills-and-keeps-what-came` — a child that
  prints forever is stopped, and the captured prefix survives.
- `confined-spawn.valid.no-network` — a child that connects fails with
  `network: false` and succeeds with it true.
- `confined-spawn.invalid.relative-path` — a relative `read` is a diagnostic.
- `confined-spawn.invalid.unconfinable-platform` — the refusal, asserted as a
  refusal rather than as a fallback.

## Build order

1. The `Confinement` and `Confined` records, and the validation that refuses a
   bad one — testable with no kernel involved at all.
2. The Linux implementation: user, mount and PID namespaces, then the mounts,
   then `execve`. No seccomp yet.
3. The timeout and the output cap, which are the two that stop a child rather
   than confining it.
4. seccomp, narrowing the syscall surface, last — because it is the layer whose
   absence is least visible and whose presence is hardest to test.
5. The platform refusal, and the diagnostic that says which platform and why.
