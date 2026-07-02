# Lumen playground compile service

A small HTTP service that powers the in-browser Lumen playground. It takes Lumen
source over HTTP, compiles it to WebAssembly, and returns the `.wasm` bytes for
the browser to run. The service only **compiles** code — it never executes user
programs, so the browser stays in control of running anything.

## API

### `POST /compile`

Send the Lumen source as the raw request body.

- **Success** → `200 OK`, `Content-Type: application/wasm`, body is the compiled
  `.wasm` module.
- **Compile error** → `400 Bad Request`, `Content-Type: application/json`, body
  is `{"error": "<diagnostic text>"}`.

```sh
# Compile and save the wasm module.
curl -s -X POST --data 'const n: int = 41; console.log(n + 1);' \
  https://<your-app>.fly.dev/compile -o out.wasm

# A program the wasm target can't build returns a 400 with the diagnostic.
curl -s -X POST --data 'console.log(undefinedName);' \
  https://<your-app>.fly.dev/compile
# -> {"error":"play.ts:1:13: error: ..."}
```

### `GET /health`

Returns `200 OK` with the body `ok`. Used for readiness checks.

### CORS

Every response (including errors and the `OPTIONS` preflight, which returns
`204`) carries permissive CORS headers so a browser playground served from any
origin can call the service:

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: POST, OPTIONS
Access-Control-Allow-Headers: Content-Type
```

## Guards

Because the service only compiles (it never runs user code), it needs just two
guards:

- **Body size**: requests larger than 512 KiB are rejected with `413`.
- **Compile timeout**: each compile is capped at 20 seconds.

The listen port comes from the `PORT` environment variable (default `8080`), and
the service binds `0.0.0.0`.

## Deploy to Fly.io

All commands are run **from the repository root** so the Docker build context
includes `src/` and `build.zig`. Edit the `app` name in `playground/fly.toml`
first (or let `fly launch` set one).

```sh
# From the repo root.

# One-time: create the Fly app without deploying yet.
fly launch --no-deploy \
  --config playground/fly.toml \
  --dockerfile playground/Dockerfile

# Build and deploy (also used for every subsequent update).
fly deploy \
  --config playground/fly.toml \
  --dockerfile playground/Dockerfile

# Warm the compile cache so the first visitor after this deploy doesn't pay
# for a cold compile on one of play.html's prefilled examples (see "Cache
# warming" below).
python3 playground/warm_cache.py https://<your-app>.fly.dev
```

### Cache warming

`server.zig` caches compiled wasm by exact source-body match (a small,
in-memory, FIFO-evicted cache — see its own doc comment), but that cache is
empty on every fresh process: a new deploy, or Fly starting a fresh machine
after scaling to zero. Since most playground visits load one of
`website/play.html`'s prefilled examples and click Run without editing, the
very first visitor after either of those would otherwise pay for a full
compile that every subsequent visitor gets instantly.

`playground/warm_cache.py` extracts every example straight from
`play.html` (mirroring its own frontend extraction exactly, so it never
needs updating when examples change) and `POST`s each one to `/compile`,
populating the cache before real traffic arrives:

```sh
python3 playground/warm_cache.py https://<your-app>.fly.dev
```

Run it right after every `fly deploy`. It has no effect on a cold start
from scale-to-zero (nothing triggers it automatically there yet) — that
first request after idling still pays for one real compile per example
that gets hit before someone deploys again.

### Scale to zero

`playground/fly.toml` configures the service to scale to zero: with
`auto_stop_machines = "stop"`, `auto_start_machines = true`, and
`min_machines_running = 0`, Fly stops the machine when traffic is idle and
starts it again on the next request. The first request after an idle period pays
a short cold-start; subsequent requests are served from the running machine.

## Local development

```sh
# From the repo root: build the compiler, then the service.
zig build
zig build-exe playground/server.zig -O ReleaseSafe -femit-bin=./server

# Run with the compiler on PATH (it is invoked by name at runtime).
PATH="$PWD/zig-out/bin:$PATH" PORT=8080 ./server
```

Then `curl` it as shown above using `localhost:8080`.
