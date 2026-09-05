// `path.*` (spec 032): pure string work on POSIX paths. `sep()` and
// `delimiter()` are calls (Lumen has no namespace constants). Everything
// below operates on the Lumen string directly: separators are ASCII, so a
// byte string and a text string agree on every split.
import npath from "node:path";
import { cwd } from "node:process";
import { bytes } from "./lang.mjs";

const posix = npath.posix;

export function basename(path, suffix = "") {
  const base = posix.basename(path);
  if (suffix.length > 0 && base.length > suffix.length && base.endsWith(suffix)) {
    return base.slice(0, base.length - suffix.length);
  }
  return base;
}

export function dirname(path) {
  return posix.dirname(path);
}

export function extname(path) {
  return posix.extname(path);
}

export function normalize(path) {
  return posix.normalize(path);
}

export function isAbsolute(path) {
  return posix.isAbsolute(path);
}

export function join(...paths) {
  return posix.join(...paths);
}

/** `resolve(...paths)`: anchored to the working directory, like Node's. */
export function resolve(...paths) {
  return posix.resolve(bytes(cwd()), ...paths);
}

export function parse(path) {
  const p = posix.parse(path);
  return { root: p.root, dir: p.dir, base: p.base, name: p.name, ext: p.ext };
}

/** `format(parts)`: every field is a plain string (spec 032); `dir` wins
 *  over `root`, `base` over `name + ext`. */
export function format(parts) {
  const dir = parts.dir.length > 0 ? parts.dir : parts.root;
  const base = parts.base.length > 0 ? parts.base : parts.name + parts.ext;
  if (dir.length === 0) return base;
  if (dir.endsWith("/")) return dir + base;
  return dir + "/" + base;
}

export function sep() {
  return "/";
}

export function delimiter() {
  return ":";
}
