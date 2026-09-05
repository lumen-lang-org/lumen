import { test } from "node:test";
import assert from "node:assert/strict";
import * as url from "../lib/url.mjs";

test("parse gives the raw components and a query Map (specs 036, 045)", () => {
  const u = url.parse("HTTP://Example.com:80/p/a%20th?a=1&b=2&a=3&noeq#frag");
  assert.equal(u.protocol, "HTTP:");
  assert.equal(u.hostname, "Example.com");
  assert.equal(u.port, "80");
  assert.equal(u.pathname, "/p/a%20th");
  assert.equal(u.search, "?a=1&b=2&a=3&noeq");
  assert.equal(u.hash, "#frag");
  assert.equal(u.href, "HTTP://Example.com:80/p/a%20th?a=1&b=2&a=3&noeq#frag");
  assert.deepEqual([...u.query], [["a", "3"], ["b", "2"]]);
});

test("an empty path is \"/\"; no scheme is the empty record with the input as href", () => {
  const u = url.parse("https://h");
  assert.equal(u.pathname, "/");
  assert.equal(u.search, "");
  assert.equal(u.query.size, 0);
  const bad = url.parse("/just/a/path");
  assert.deepEqual({ ...bad, query: [...bad.query] }, { protocol: "", hostname: "", port: "", pathname: "/", search: "", hash: "", href: "/just/a/path", query: [] });
  assert.equal(url.parse("mailto:a@b").hostname, "");
  assert.equal(url.parse("mailto:a@b").pathname, "a@b");
});

test("format rebuilds protocol//host[:port]path?search#hash", () => {
  const u = url.parse("http://h:8080/x?y=1#z");
  assert.equal(url.format(u), "http://h:8080/x?y=1#z");
  assert.equal(url.format({ protocol: "http:", hostname: "h", port: "", pathname: "/", search: "", hash: "" }), "http://h/");
});
