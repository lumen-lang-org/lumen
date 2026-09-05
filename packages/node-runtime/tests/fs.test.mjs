import { test } from "node:test";
import assert from "node:assert/strict";
import nfs from "node:fs";
import { join } from "node:path";
import * as fs from "../lib/fs.mjs";
import { scratch } from "./helpers.mjs";

test("readFileSync returns the bytes as a string; a missing file throws the native message", () => scratch((dir) => {
  const f = join(dir, "a.txt");
  nfs.writeFileSync(f, Buffer.from([0x68, 0xc3, 0xa9]));
  assert.equal(fs.readFileSync(f), "h\xc3\xa9");
  assert.equal(fs.readFileSync(f, "utf8"), "h\xc3\xa9");
  assert.throws(() => fs.readFileSync(join(dir, "nope")), /^Error: cannot read '.*nope': ENOENT$/);
}));

test("writeFileSync/appendFileSync write bytes; a bad path throws", () => scratch((dir) => {
  const f = join(dir, "w.txt");
  fs.writeFileSync(f, "\xc3\xa9");
  fs.appendFileSync(f, "!");
  assert.deepEqual([...nfs.readFileSync(f)], [0xc3, 0xa9, 0x21]);
  assert.throws(() => fs.writeFileSync(join(dir, "no/dir/x"), "x"), /cannot write '.*x': ENOENT/);
  assert.throws(() => fs.appendFileSync(join(dir, "no/dir/x"), "x"), /cannot append to '.*x': ENOENT/);
}));

test("mkdirSync(path, recursive?): an existing directory is not a failure; a missing parent is", () => scratch((dir) => {
  fs.mkdirSync(join(dir, "one"));
  fs.mkdirSync(join(dir, "one"));
  assert.throws(() => fs.mkdirSync(join(dir, "a/b/c")), /cannot make '.*c': ENOENT/);
  fs.mkdirSync(join(dir, "a/b/c"), true);
  assert.ok(nfs.statSync(join(dir, "a/b/c")).isDirectory());
}));

test("existsSync/accessSync/realpathSync/readlinkSync fall back to false, false, the path, \"\"", () => scratch((dir) => {
  const f = join(dir, "f");
  nfs.writeFileSync(f, "x");
  assert.equal(fs.existsSync(f), true);
  assert.equal(fs.existsSync(join(dir, "g")), false);
  assert.equal(fs.accessSync(f), true);
  assert.equal(fs.accessSync(f, 4), true);
  assert.equal(fs.accessSync(join(dir, "g")), false);
  assert.equal(fs.realpathSync(join(dir, "g")), join(dir, "g"));
  assert.equal(fs.readlinkSync(f), "");
  fs.symlinkSync(f, join(dir, "link"));
  assert.equal(fs.readlinkSync(join(dir, "link")), f);
  assert.equal(fs.realpathSync(join(dir, "link")), nfs.realpathSync(f));
}));

test("statSync/lstatSync/fstatSync give the four-field record; missing gives zeros (spec 031)", () => scratch((dir) => {
  const f = join(dir, "s");
  nfs.writeFileSync(f, "12345");
  const st = fs.statSync(f);
  assert.deepEqual(Object.keys(st).sort(), ["isDirectory", "isFile", "mtimeMs", "size"]);
  assert.equal(st.size, 5);
  assert.equal(st.isFile, true);
  assert.equal(st.isDirectory, false);
  assert.ok(Number.isInteger(st.mtimeMs));
  assert.equal(fs.statSync(dir).isDirectory, true);
  assert.deepEqual(fs.statSync(join(dir, "none")), { size: 0, isFile: false, isDirectory: false, mtimeMs: 0 });
  assert.equal(fs.lstatSync(f).size, 5);
  const fd = fs.openSync(f, "r");
  assert.equal(fs.fstatSync(fd).size, 5);
  fs.closeSync(fd);
  assert.deepEqual(fs.fstatSync(-1), { size: 0, isFile: false, isDirectory: false, mtimeMs: 0 });
}));

test("openSync/readSync/writeSync/closeSync: -1, \"\" and 0 on failure", () => scratch((dir) => {
  const f = join(dir, "fd.txt");
  const w = fs.openSync(f, "w");
  assert.ok(w >= 0);
  assert.equal(fs.writeSync(w, "hello\n"), 6);
  fs.closeSync(w);
  const a = fs.openSync(f, "a");
  assert.equal(fs.writeSync(a, "more"), 4);
  fs.closeSync(a);
  const r = fs.openSync(f, "r");
  assert.equal(fs.readSync(r, 5), "hello");
  assert.equal(fs.readSync(r, 0), "");
  assert.equal(fs.readSync(r, 100), "\nmore");
  assert.equal(fs.readSync(r, 100), "");
  fs.closeSync(r);
  fs.closeSync(r);
  assert.equal(fs.openSync(join(dir, "missing/x"), "r"), -1);
  assert.equal(fs.readSync(-1, 10), "");
  assert.equal(fs.writeSync(-1, "x"), 0);
}));

test("readvSync/writevSync are one vectored call each", () => scratch((dir) => {
  const f = join(dir, "v.txt");
  const w = fs.openSync(f, "w");
  assert.equal(fs.writevSync(w, ["ab", "cde"]), 5);
  fs.closeSync(w);
  const r = fs.openSync(f, "r");
  assert.deepEqual(fs.readvSync(r, [2, 10]), ["ab", "cde"]);
  fs.closeSync(r);
  assert.deepEqual(fs.readvSync(-1, [1]), []);
  assert.equal(fs.writevSync(-1, ["x"]), 0);
}));

test("readdirSync lists names, [] for a missing directory", () => scratch((dir) => {
  nfs.writeFileSync(join(dir, "b"), "");
  nfs.writeFileSync(join(dir, "a"), "");
  assert.deepEqual(fs.readdirSync(dir).sort(), ["a", "b"]);
  assert.deepEqual(fs.readdirSync(join(dir, "none")), []);
}));

test("rename/copy throw with both paths; rm/rmdir/unlink/truncate/link/chmod are silent on failure", () => scratch((dir) => {
  const a = join(dir, "a"), b = join(dir, "b");
  nfs.writeFileSync(a, "x");
  fs.renameSync(a, b);
  fs.copyFileSync(b, a);
  assert.equal(nfs.readFileSync(a, "utf8"), "x");
  assert.throws(() => fs.renameSync(join(dir, "zz"), b), /cannot rename '.*zz' to '.*b': ENOENT/);
  assert.throws(() => fs.copyFileSync(join(dir, "zz"), b), /cannot copy '.*zz' to '.*b': ENOENT/);
  fs.unlinkSync(b);
  assert.throws(() => fs.unlinkSync(b), /cannot delete '.*b': ENOENT/);
  fs.rmdirSync(join(dir, "none"));
  fs.rmSync(join(dir, "none"));
  fs.truncateSync(join(dir, "none"), 0);
  fs.linkSync(join(dir, "none"), join(dir, "none2"));
  fs.chmodSync(join(dir, "none"), 0o600);
  fs.mkdirSync(join(dir, "tree/deep"), true);
  fs.rmSync(join(dir, "tree"));
  assert.ok(nfs.existsSync(join(dir, "tree")));
  fs.rmSync(join(dir, "tree"), true);
  assert.ok(!nfs.existsSync(join(dir, "tree")));
  fs.truncateSync(a, 0);
  assert.equal(nfs.statSync(a).size, 0);
}));

test("cpSync copies a tree only when asked; mkdtempSync is prefix + 8 hex digits, \"\" when it cannot", () => scratch((dir) => {
  fs.mkdirSync(join(dir, "src/inner"), true);
  nfs.writeFileSync(join(dir, "src/inner/f"), "1");
  fs.cpSync(join(dir, "src"), join(dir, "dst"));
  assert.ok(!nfs.existsSync(join(dir, "dst")));
  fs.cpSync(join(dir, "src"), join(dir, "dst"), true);
  assert.equal(nfs.readFileSync(join(dir, "dst/inner/f"), "utf8"), "1");
  const t = fs.mkdtempSync(join(dir, "tmp-"));
  assert.match(t, /tmp-[0-9a-f]{8}$/);
  assert.ok(nfs.statSync(t).isDirectory());
  assert.equal(fs.mkdtempSync(join(dir, "nodir/tmp-")), "");
}));

test("createReadStream: read() chunks, readLine() keeps \"\\n\", \"\" at EOF and for a missing file (spec 046/053)", () => scratch((dir) => {
  const f = join(dir, "lines.txt");
  nfs.writeFileSync(f, "one\n\ntwo");
  const s = fs.createReadStream(f);
  assert.equal(s.readLine(), "one\n");
  assert.equal(s.readLine(), "\n");
  assert.equal(s.readLine(), "two");
  assert.equal(s.readLine(), "");
  s.close();
  const r = fs.createReadStream(f);
  assert.equal(r.read(), "one\n\ntwo");
  assert.equal(r.read(), "");
  r.close();
  const m = fs.createReadStream(join(dir, "none"));
  assert.equal(m.read(), "");
  assert.equal(m.readLine(), "");
  m.close();
}));

test("createWriteStream writes bytes; an unopenable path swallows writes", () => scratch((dir) => {
  const f = join(dir, "out.txt");
  const w = fs.createWriteStream(f);
  w.write("a");
  w.write("\xff");
  w.close();
  assert.deepEqual([...nfs.readFileSync(f)], [0x61, 0xff]);
  const bad = fs.createWriteStream(join(dir, "no/out.txt"));
  bad.write("x");
  bad.close();
}));

test("the async set resolves with the sync fallbacks (spec 047)", async () => {
  await scratch(async (dir) => {
    const f = join(dir, "async.txt");
    await fs.writeFile(f, "a");
    await fs.appendFile(f, "b");
    assert.equal(await fs.readFile(f), "ab");
    assert.equal(await fs.readFile(join(dir, "none")), "");
    assert.equal((await fs.stat(f)).size, 2);
    assert.deepEqual(await fs.stat(join(dir, "none")), { size: 0, isFile: false, isDirectory: false, mtimeMs: 0 });
    await fs.mkdir(join(dir, "d"));
    await fs.rmdir(join(dir, "d"));
    await fs.unlink(f);
    await fs.unlink(f);
    assert.ok(!nfs.existsSync(f));
  });
});

test("utimes/futimes take milliseconds", () => scratch((dir) => {
  const f = join(dir, "t");
  nfs.writeFileSync(f, "");
  fs.utimesSync(f, 1000000, 2000000);
  assert.equal(Math.round(nfs.statSync(f).mtimeMs), 2000000);
  const fd = fs.openSync(f, "r");
  fs.futimesSync(fd, 3000000, 4000000);
  fs.closeSync(fd);
  assert.equal(Math.round(nfs.statSync(f).mtimeMs), 4000000);
  fs.lutimesSync(f, 5000000, 6000000);
  assert.equal(Math.round(nfs.statSync(f).mtimeMs), 6000000);
}));

test("watch reports change/rename and keeps the listener alive", async () => {
  await scratch(async (dir) => {
    const events = [];
    const w = fs.watch(dir, (name, ev) => events.push([name, ev]));
    await new Promise((r) => setTimeout(r, 50));
    nfs.writeFileSync(join(dir, "n"), "x");
    await new Promise((r) => setTimeout(r, 200));
    w.close();
    assert.ok(events.some(([name]) => name === "n"));
    assert.ok(events.every(([, ev]) => ev === "change" || ev === "rename"));
  });
});
