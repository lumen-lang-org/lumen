# Feature Specification: HTTP Request Headers

## Problem

`http.createServer(port, handler)` hands the handler a request with three
fields — `method`, `path`, `body` (`registerLumenHttpRequest`,
`src/lumen_check_stdlib.zig`). There are no headers, so a server cannot read
`Authorization`, cannot read `Content-Type`, and cannot authenticate a request
at all. Every server built on it is anonymous by construction.

The information was never missing at run time: the connection loop already
parses the header block to find `Content-Length` and to honour
`Connection: close`, then throws it away. This surfaces what is already read.

## Design

`headers: Map<string,string>` on the request, built exactly as the response's
`headers` field is (same construction, same annotation), so one shape answers
for headers in both directions and a handler can pass one to the other.

Parsing rules, all of them decided by what a server must survive:

- **Names are lowercased.** `Authorization` and `authorization` are the same
  header, and the client picks the spelling. Lowercasing at the door makes
  `headers.get("authorization")` a lookup rather than a search — and makes the
  lowercase name the *only* key, so `get("Authorization")` finds nothing.
- **A repeated header keeps the last value**, which is what setting the same
  key twice on a `Map` does.
- **A header with no value, or no name, is dropped.** A line with no colon at
  all never gets that far — the existing parse skips it.
- **The request line is not a header.** It is read before the header loop and
  never reaches the map.
- **Malformed input does not end the server.** Every failure above is a skipped
  line, not a closed connection.

The map is built in the connection arena, not the process-wide one: it is valid
for the handler call and no longer, exactly like the `method`/`path`/`body`
slices beside it. A per-request allocation in a process-lifetime arena would
grow a server that is meant to run forever, and the arena is per-connection, so
no two worker threads share one.

All four connection loops get it — buffered and streaming, thread-pool and the
single-threaded wasm fallback — through one shared pair of prelude helpers, so
the four cannot drift apart.

## Not planned here

- **Response headers on the client side.** `http.request`'s response still
  carries an empty header map; that is spec 045's documented follow-up and
  needs the lower-level client flow beneath `fetch`.
- **Repeated headers as a list.** `Set-Cookie` is the header that wants it, and
  it is a response header, not a request one.

## Conformance

`specs/459-http-request-headers/conformance/manifest.json`:

| case | phase | proves |
| --- | --- | --- |
| `reqheaders.valid.read-request-headers` | static | a buffered handler reads headers, with `??` for one that was not sent |
| `reqheaders.valid.map-methods-apply` | static | the headers are an ordinary `Map<string,string>`: `has`, `size`, `keys` |
| `reqheaders.valid.streaming-handler-reads-them-too` | static | the two-parameter streaming handler gets the same request record |
| `reqheaders.invalid.value-is-a-string` | diagnostics | a header value is text; `?? 0` is a type error, not a coincidence |
| `reqheaders.invalid.headers-map-string-to-string` | diagnostics | the type is `Map<string,string>` and says so |

A server never returns, so the parsing rules are checked by hand against a real
client instead: `examples/manual/header-echo.ts` carries the `curl` and raw-`nc`
invocations and what they print.
