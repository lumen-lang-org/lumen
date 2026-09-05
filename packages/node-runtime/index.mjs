// Every Lumen namespace as a named export. Importing this installs nothing
// (spec 503 FR-004); `./globals.mjs` is the entry that puts them on
// `globalThis` for a Lumen program.
import * as fs from "./lib/fs.mjs";
import * as path from "./lib/path.mjs";
import * as os from "./lib/os.mjs";
import * as crypto from "./lib/crypto.mjs";
import * as child_process from "./lib/child_process.mjs";
import * as net from "./lib/net.mjs";
import * as http from "./lib/http.mjs";
import * as zlib from "./lib/zlib.mjs";
import * as url from "./lib/url.mjs";
import * as time from "./lib/time.mjs";
import * as readline from "./lib/readline.mjs";
import * as assert from "./lib/assert.mjs";
import * as lang from "./lib/lang.mjs";
import * as builtins from "./lib/builtins.mjs";

export { fs, path, os, crypto, child_process, net, http, zlib, url, time, readline, assert, lang };
export { process, argsCount, arg, installProcess } from "./lib/process.mjs";
export { Buffer } from "./lib/buffer.mjs";
export { EventEmitter } from "./lib/events.mjs";
export { Worker } from "./lib/worker.mjs";
export { test, expect } from "./lib/test.mjs";
export { defer, divInt, bytes, text, toBuffer, fromBuffer, errorMessage } from "./lib/lang.mjs";
export { ReadableStream, WritableStream } from "./lib/streams.mjs";
export { builtins };
export { installBuiltins } from "./lib/builtins.mjs";
