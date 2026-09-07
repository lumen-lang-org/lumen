// SC-002: process.sleep(250) blocks for at least 250ms, measured against
// the awake clock -- spec 475's contract, on both targets. Node's version
// re-arms a follow-up timer if one setTimeout call would undershoot (the
// spike's 0.34ms finding, spec 508's plan.md).
const before: i64 = time.monotonic();
process.sleep(250);
const elapsed: i64 = time.monotonic() - before;
console.log(elapsed >= 250 ? "ok" : `too fast: ${elapsed}`);
