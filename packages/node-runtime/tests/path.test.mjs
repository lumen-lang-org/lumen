import { test } from "node:test";
import assert from "node:assert/strict";
import * as path from "../lib/path.mjs";

test("basename(p, suffix) strips only a proper suffix (spec 032)", () => {
  assert.equal(path.basename("/a/b/c.txt"), "c.txt");
  assert.equal(path.basename("/a/b/c.txt", ".txt"), "c");
  assert.equal(path.basename(".txt", ".txt"), ".txt");
  assert.equal(path.basename("/a/b/"), "b");
});

test("dirname/extname/normalize/isAbsolute/join/resolve", () => {
  assert.equal(path.dirname("/a/b/c"), "/a/b");
  assert.equal(path.dirname("c"), ".");
  assert.equal(path.extname("x.tar.gz"), ".gz");
  assert.equal(path.normalize("/a//b/../c/"), "/a/c/");
  assert.equal(path.isAbsolute("/x"), true);
  assert.equal(path.isAbsolute("x"), false);
  assert.equal(path.join("a", "..", "b", "c"), "b/c");
  assert.equal(path.resolve("/x", "y"), "/x/y");
  assert.equal(path.resolve("rel"), process.cwd() + "/rel");
});

test("parse/format round-trip; format prefers dir over root and base over name+ext", () => {
  const p = path.parse("/home/u/file.txt");
  assert.deepEqual(p, { root: "/", dir: "/home/u", base: "file.txt", name: "file", ext: ".txt" });
  assert.equal(path.format(p), "/home/u/file.txt");
  assert.equal(path.format({ root: "/", dir: "", base: "x", name: "", ext: "" }), "/x");
  assert.equal(path.format({ root: "", dir: "", base: "", name: "n", ext: ".e" }), "n.e");
  assert.equal(path.format({ root: "", dir: "d/", base: "b", name: "", ext: "" }), "d/b");
});

test("sep() and delimiter() are calls", () => {
  assert.equal(path.sep(), "/");
  assert.equal(path.delimiter(), ":");
});
