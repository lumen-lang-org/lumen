// `time.*` (spec 041): milliseconds as `i64`. `now()` is wall-clock epoch
// time; `monotonic()` never goes backwards and has no meaningful origin.
import { hrtime } from "node:process";

export function now() {
  return Date.now();
}

export function monotonic() {
  return Number(hrtime.bigint() / 1000000n);
}
