import { test } from "node:test";
import assert from "node:assert/strict";
import nos from "node:os";
import * as os from "../lib/os.mjs";

const isInt32 = (n) => Number.isInteger(n) && n >= -(2 ** 31) && n < 2 ** 31;

test("constants are calls: EOL(), devNull(), platform(), arch()", () => {
  assert.equal(os.EOL(), "\n");
  assert.equal(os.devNull(), "/dev/null");
  assert.equal(os.platform(), ["linux", "darwin", "win32", "freebsd", "openbsd"].includes(process.platform) ? process.platform : "unknown");
  assert.equal(os.arch(), ["x64", "ia32", "arm64", "arm", "riscv64"].includes(process.arch) ? process.arch : "unknown");
});

test("uname fields, endianness, hostname come from the system", () => {
  assert.equal(os.type(), nos.type());
  assert.equal(os.release(), nos.release());
  assert.equal(os.version(), nos.version());
  assert.equal(os.machine(), nos.machine());
  assert.equal(os.hostname(), nos.hostname());
  assert.ok(["LE", "BE"].includes(os.endianness()));
});

test("tmpdir() reads TMPDIR, TMP, TEMP then /tmp; homedir() is $HOME or \"\"", () => {
  const saved = { TMPDIR: process.env.TMPDIR, TMP: process.env.TMP, TEMP: process.env.TEMP, HOME: process.env.HOME };
  try {
    delete process.env.TMPDIR; delete process.env.TMP; delete process.env.TEMP;
    assert.equal(os.tmpdir(), "/tmp");
    process.env.TEMP = "/t3"; assert.equal(os.tmpdir(), "/t3");
    process.env.TMP = "/t2"; assert.equal(os.tmpdir(), "/t2");
    process.env.TMPDIR = "/t1/"; assert.equal(os.tmpdir(), "/t1/");
    process.env.HOME = "/h"; assert.equal(os.homedir(), "/h");
    delete process.env.HOME; assert.equal(os.homedir(), "");
  } finally {
    for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  }
});

test("the numeric results are int (32-bit), loadavg is three floats", () => {
  assert.ok(isInt32(os.uptime()));
  assert.ok(isInt32(os.totalmem()));
  assert.ok(isInt32(os.freemem()));
  assert.ok(isInt32(os.availableParallelism()) && os.availableParallelism() >= 1);
  const l = os.loadavg();
  assert.equal(l.length, 3);
  assert.ok(l.every((x) => typeof x === "number"));
});
