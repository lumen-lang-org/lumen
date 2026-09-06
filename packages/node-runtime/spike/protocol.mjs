// Shared layout between the main thread and the broker worker.
// control: Int32Array(6) over a SharedArrayBuffer.
export const STATE = 0;      // 0=idle 1=request-posted 2=response-ready
export const REQ_ID = 1;
export const OP = 2;
export const ARG_LEN = 3;
export const RESP_LEN = 4;
export const RESP_STATUS = 5;

export const IDLE = 0;
export const REQUEST_POSTED = 1;
export const RESPONSE_READY = 2;

export const OP_SLEEP = 1;
export const OP_CONNECT = 2;
export const OP_READ = 3;
export const OP_WRITE = 4;
export const OP_CLOSE = 5;

export const DATA_BYTES = 70 * 1024; // headroom over the 64KB chunk spec 054 documents
export const CONTROL_WORDS = 6;
