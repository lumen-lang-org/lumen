# Feature Specification: The Open-File Table Is Shared

## Problem

`fs.openSync` appends to a process-global list:

```zig
var __fd_table: std.ArrayListUnmanaged(std.Io.File) = .empty;
```

and every other file call indexes it:

```zig
__fd_table.items[@intCast(fd)].readStreaming(io, &.{buf})
```

`http.createServer` hands each request to a worker thread, so two handlers
opening files at once append concurrently. An append that grows the list
allocates a new array and frees the old one — while another thread is reading
`items[fd]` out of it. A handler reads from a freed array, or from a file
another request opened.

Nothing reports this. The read returns bytes, they are simply the wrong ones,
or the process dies somewhere unrelated later.

## Scope

In scope:

- Concurrent `openSync`, `readSync`, `writeSync` and `closeSync` from worker
  threads are safe.
- No change to the fd numbering a program sees.

Out of scope:

- Reclaiming slots on close. `closeSync` closes the file and leaves the entry,
  which is what it did before; a program opening files in a loop still grows
  the table. Worth fixing, but it is a leak rather than a race.
- The other process-global state spec 468 moved onto the thread. This one
  cannot move: a file opened by one handler is closed by the same handler, but
  the table itself is genuinely shared.

## Design

### D1 — the lock covers the table, not the I/O

A `std.Io.Mutex` guards the list. `__fdAt(io, fd)` takes it, copies the
`std.Io.File` out, and releases it; the read or write then happens outside the
lock.

A `File` is a small handle, so copying it is cheap. Holding the lock across a
blocking read would serialise every file operation in the process to fix a
problem that is only about the backing array's lifetime.

### D2 — why not thread-local

Spec 468 moved the line, column, throw flag and call stack onto the thread,
because each is per call stack. This is not: a descriptor is a number a program
passes around, and nothing says the thread that opens a file is the thread that
reads it. The table is shared on purpose and needs a lock rather than a move.

## Success Criteria

1. 96 concurrent requests, each opening its own file, writing a tag, reading it
   back and answering with it, return their own tag every time.
2. Sequential file use is unchanged: open, write, close, open, read, close.
3. A negative or out-of-range descriptor still reads `""` and writes 0.
4. `zig build test` passes; `zig build conformance` adds no new failures.

## Notes

Found by an audit while fixing spec 468 and left alone at the time, because it
is a different kind of bug: 468's state wanted moving, this wants locking.

`std.Thread.Mutex` does not exist in Zig 0.16 — the mutex is `std.Io.Mutex`,
taking the `io` handle on lock and unlock. The same file already used it for
`__fs_done_mutex`, which is where the pattern came from.
