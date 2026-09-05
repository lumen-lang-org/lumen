import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "../lib/events.mjs";

test("on/once/emit in registration order; once listeners go after their emit (spec 043)", () => {
  const e = new EventEmitter();
  const log = [];
  e.on("x", (v) => log.push("a" + v));
  e.once("x", (v) => log.push("b" + v));
  e.on("x", (v) => log.push("c" + v));
  e.emit("x", 1);
  e.emit("x", 2);
  e.emit("y", 3);
  assert.deepEqual(log, ["a1", "b1", "c1", "a2", "c2"]);
  assert.equal(e.listenerCount("x"), 2);
  assert.equal(e.listenerCount("none"), 0);
});

test("removeAllListeners(name) clears one name, removeAllListeners() every name", () => {
  const e = new EventEmitter();
  e.on("x", () => {});
  e.on("y", () => {});
  e.removeAllListeners("x");
  assert.equal(e.listenerCount("x"), 0);
  assert.equal(e.listenerCount("y"), 1);
  e.removeAllListeners();
  assert.equal(e.listenerCount("y"), 0);
});
