#!/usr/bin/env python3
"""Extract the stdlib names the checker accepts, per namespace.

The checker is the contract for the Node runtime package (spec 503 FR-001):
every name compared against `call.name` inside a `<ns>CallType` function in
`src/lumen_check_stdlib.zig` / `src/lumen_check_stdlib_os.zig`, every method
name compared against `mc.name` inside a `<Receiver>Method` function in
`src/lumen_check_methods.zig`, and the handful of bare globals the parser and
`lumen_check_expr.zig` recognise. Writes JSON to stdout or to `--out`.

    python3 tools/stdlib_names.py --out packages/node-runtime/tests/names.json
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# `<fn name>` -> namespace as a Lumen program spells it. The namespaces that
# are JavaScript's own (Math, String, Array, Number, JSON, Date, Promise) are
# listed too: the package supplies the names Lumen adds to them
# (`Math.clamp`, `String.contains`, ...) and JavaScript the rest.
CALL_TYPE_FNS = {
    "mathCallType": "Math",
    "stringCallType": "String",
    "arrayCallType": "Array",
    "numberCallType": "Number",
    "jsonCallType": "JSON",
    "dateCallType": "Date",
    "promiseCallType": "Promise",
    "fsCallType": "fs",
    "pathCallType": "path",
    "processCallType": "process",
    "osCallType": "os",
    "readlineCallType": "readline",
    "childProcessCallType": "child_process",
    "cryptoCallType": "crypto",
    "zlibCallType": "zlib",
    "urlCallType": "url",
    "assertCallType": "assert",
    "timeCallType": "time",
    "httpCallType": "http",
    "netCallType": "net",
    "bufferCallType": "Buffer",
    "workerCallType": "Worker",
}

METHOD_FNS = {
    "eventEmitterMethod": "EventEmitter",
    "readableStreamMethod": "ReadableStream",
    "writableStreamMethod": "WritableStream",
    "socketMethod": "Socket",
    "childProcessMethod": "ChildProcess",
    "httpStreamMethod": "HttpStream",
    "responseWriterMethod": "ResponseWriter",
    "bufferMethod": "Buffer",
    "hashMethod": "Hash",
    "hmacMethod": "Hmac",
}

# Bare calls a program makes without a namespace. Each is checked to exist
# in the source it is attributed to, so a renamed builtin fails loudly here.
GLOBALS = {
    "argsCount": ("src/lumen_check_expr.zig", 'call.name, "argsCount"'),
    "arg": ("src/lumen_check_expr.zig", 'call.name, "arg"'),
    "expect": ("src/lumen_check_expr.zig", 'call.name, "expect"'),
    "test": ("src/lumen_parser.zig", 'kw, "test"'),
    "defer": ("src/lumen_parser.zig", 'kw, "defer"'),
}

FN_HEADER = re.compile(r"^pub fn (\w+)\(", re.M)
NAME_CMP = re.compile(r'(?:eql|eq)\(u8,\s*(?:call\.name|name|mc\.name),\s*"([A-Za-z_][A-Za-z0-9_]*)"\)')
NAME_ARRAY = re.compile(r"\[_\]\[\]const u8\{([^}]*)\}")
STRING_LIT = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*)"')


def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def function_bodies(src):
    """Yield (name, body) for every `pub fn` at column 0."""
    heads = list(FN_HEADER.finditer(src))
    for i, m in enumerate(heads):
        end = heads[i + 1].start() if i + 1 < len(heads) else len(src)
        yield m.group(1), src[m.start():end]


def names_in(body):
    found = set(NAME_CMP.findall(body))
    for arr in NAME_ARRAY.findall(body):
        found.update(STRING_LIT.findall(arr))
    # Internal routing names the checker rewrites *to* (never user-facing)
    # start with a double underscore; a program cannot spell them.
    return sorted(n for n in found if not n.startswith("__"))


def collect():
    namespaces = {}
    for rel in ("src/lumen_check_stdlib.zig", "src/lumen_check_stdlib_os.zig"):
        for fn, body in function_bodies(read(rel)):
            ns = CALL_TYPE_FNS.get(fn)
            if ns is None:
                continue
            namespaces.setdefault(ns, set()).update(names_in(body))
    methods = {}
    for fn, body in function_bodies(read("src/lumen_check_methods.zig")):
        recv = METHOD_FNS.get(fn)
        if recv is None:
            continue
        methods.setdefault(recv, set()).update(names_in(body))
    missing = [n for n, (rel, needle) in GLOBALS.items() if needle not in read(rel)]
    if missing:
        sys.exit("stdlib_names: global(s) not found where expected: " + ", ".join(missing))
    unmatched_fns = [fn for fn in CALL_TYPE_FNS if CALL_TYPE_FNS[fn] not in namespaces]
    unmatched_fns += [fn for fn in METHOD_FNS if METHOD_FNS[fn] not in methods]
    if unmatched_fns:
        sys.exit("stdlib_names: checker function(s) not found: " + ", ".join(unmatched_fns))
    return {
        "generated_by": "tools/stdlib_names.py",
        "sources": [
            "src/lumen_check_stdlib.zig",
            "src/lumen_check_stdlib_os.zig",
            "src/lumen_check_methods.zig",
            "src/lumen_check_expr.zig",
            "src/lumen_parser.zig",
        ],
        "namespaces": {k: sorted(v) for k, v in sorted(namespaces.items())},
        "methods": {k: sorted(v) for k, v in sorted(methods.items())},
        "globals": sorted(GLOBALS),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", help="write here instead of stdout")
    args = ap.parse_args()
    text = json.dumps(collect(), indent=2) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
