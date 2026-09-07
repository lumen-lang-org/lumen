// Wire layout for spec 511's T001 spike: ONE SharedArrayBuffer control/data
// pair per handle (plan.md decision 2), not the single shared pair spec
// 508's broker uses. Deliberately a near-copy of ../protocol.mjs's shape --
// the point of this spike is to prove that giving each handle its own pair
// and using Atomics.waitAsync (not Atomics.wait) on the CALLING side lets N
// handles' requests resolve independently and concurrently, not the wire
// format itself, which barely needs to change.
export const STATE = 0; // 0=idle 1=request-posted 2=response-ready
export const OP = 1;
export const ARG_LEN = 2;
export const RESP_STATUS = 3;
export const RESP_LEN = 4;
export const CONTROL_WORDS = 5;

export const IDLE = 0;
export const REQUEST_POSTED = 1;
export const RESPONSE_READY = 2;

// One op is enough to prove the concurrency property: sleep `ms`, then
// echo `tag` back. A real handle's read/write op would carry byte payloads
// instead of this JSON test payload -- the spike keeps it simple, the
// point is the concurrency of the wait, not the payload encoding (already
// solved by spec 508's own protocol.mjs).
export const OP_SLEEP_ECHO = 1;

export const DATA_BYTES = 4096;
