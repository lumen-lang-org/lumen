// The main-thread-facing synchronous API. Every call here genuinely blocks
// this thread's event loop via Atomics.wait -- no timer, no I/O callback,
// no console.log flush runs until the broker answers.
import { Worker } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';
import * as P from './protocol.mjs';

const controlSAB = new SharedArrayBuffer(P.CONTROL_WORDS * 4);
const dataSAB = new SharedArrayBuffer(P.DATA_BYTES);
const control = new Int32Array(controlSAB);
const data = new Uint8Array(dataSAB);

const brokerUrl = new URL('./broker.mjs', import.meta.url);
const worker = new Worker(fileURLToPath(brokerUrl), { workerData: { controlSAB, dataSAB } });
worker.unref();

let reqId = 0;

function call(op, args, timeoutMs) {
  const argBytes = args ? Buffer.from(JSON.stringify(args), 'utf8') : Buffer.alloc(0);
  data.set(argBytes, 0);
  Atomics.store(control, P.ARG_LEN, argBytes.length);
  Atomics.store(control, P.OP, op);
  Atomics.store(control, P.REQ_ID, ++reqId);
  Atomics.store(control, P.STATE, P.REQUEST_POSTED);
  Atomics.notify(control, P.STATE);

  const r = Atomics.wait(control, P.STATE, P.REQUEST_POSTED, timeoutMs ?? Infinity);
  if (r === 'timed-out') throw new Error('sync_bridge: broker did not answer in time');
  const status = Atomics.load(control, P.RESP_STATUS);
  const len = Atomics.load(control, P.RESP_LEN);
  const bytes = Buffer.from(data.slice(0, len));
  Atomics.store(control, P.STATE, P.IDLE);
  return { status, bytes };
}

export function syncSleep(ms) {
  call(P.OP_SLEEP, { ms });
}

export function syncConnect(host, port) {
  const { status, bytes } = call(P.OP_CONNECT, { host, port });
  if (status !== 0) throw new Error('connect failed');
  return JSON.parse(bytes.toString('utf8')).handle;
}

// Mirrors Socket.read() (spec 054): the next chunk, "" (empty buffer) at EOF.
export function syncRead(handle) {
  const { status, bytes } = call(P.OP_READ, { handle });
  if (status < 0) throw new Error('read failed, status ' + status);
  return bytes; // zero-length at EOF (status 1) or on a closed/idle socket
}

export function syncWrite(handle, buf) {
  call(P.OP_WRITE, { handle, dataB64: buf.toString('base64') });
}

export function syncClose(handle) {
  call(P.OP_CLOSE, { handle });
}

export function shutdownBridge() {
  worker.terminate();
}
