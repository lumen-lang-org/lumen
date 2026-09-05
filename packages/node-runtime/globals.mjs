// `node --import @lumen-lang/node/globals program.ts`: installs every Lumen
// namespace on `globalThis` and grafts Lumen's `process.*` calls onto Node's
// `process`. A Lumen program never imports its standard library, so this is
// the one module a generated entry file (spec 504) imports.
import * as L from "./index.mjs";

const g = globalThis;

function install(name, value) {
  Object.defineProperty(g, name, { value, configurable: true, writable: true, enumerable: false });
}

install("fs", L.fs);
install("path", L.path);
install("os", L.os);
install("crypto", L.crypto);
install("child_process", L.child_process);
install("net", L.net);
install("http", L.http);
install("zlib", L.zlib);
install("url", L.url);
install("time", L.time);
install("readline", L.readline);
install("assert", L.assert);
install("Buffer", L.Buffer);
install("EventEmitter", L.EventEmitter);
install("Worker", L.Worker);
install("test", L.test);
install("expect", L.expect);
install("defer", L.defer);
install("argsCount", L.argsCount);
install("arg", L.arg);
install("__lang", L.lang);
L.installProcess(g.process);
L.installBuiltins(g);
