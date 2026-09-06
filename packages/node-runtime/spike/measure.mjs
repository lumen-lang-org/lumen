import { syncSleep, syncConnect, syncRead, shutdownBridge } from './sync_bridge.mjs';
import { startDumpServerProcess } from './proc_server_client.mjs';

function fmtMs(n) { return n.toFixed(2) + 'ms'; }

// --- 1. Protocol round-trip latency: many zero-work sleep(0) calls -----
{
  const N = 500;
  const t0 = performance.now();
  for (let i = 0; i < N; i++) syncSleep(0);
  const total = performance.now() - t0;
  console.log(`[latency] ${N} round-trips (sleep(0) through the broker): total ${fmtMs(total)}, avg ${fmtMs(total / N)}/call`);
}

// --- 2. process.sleep(250) actually takes >= 250ms, and the main thread ---
//        is genuinely blocked for it: a setInterval armed just before must
//        not tick during the wait.
{
  let ticks = 0;
  const timer = setInterval(() => { ticks++; }, 10);
  const t0 = performance.now();
  syncSleep(250);
  const elapsed = performance.now() - t0;
  const ticksDuringBlock = ticks; // read immediately on resume, before this thread's
                                   // own event loop gets a chance to run the timer
  clearInterval(timer);
  console.log(`[blocking] syncSleep(250) took ${fmtMs(elapsed)} (>= 250 required: ${elapsed >= 250})`);
  console.log(`[blocking] a 10ms main-thread interval ticked ${ticksDuringBlock} times during a 250ms block (must be 0 to prove the thread was genuinely blocked, not merely async-waiting)`);
}

// --- 3. Throughput of a 64KB-chunked read loop over a real socket, ---
//        bridged vs. a direct in-process baseline for comparison.
{
  const TOTAL = 8 * 1024 * 1024; // 8MB
  const CHUNK = 64 * 1024;

  // Baseline: a plain in-process net.Socket, no bridge, no worker -- against
  // the SAME kind of out-of-process peer the bridged run uses below, so the
  // comparison isolates the bridge's overhead rather than an unrelated
  // same-process-vs-cross-process difference.
  const netMod = await import('node:net');
  const { child: baseChild, port: basePort } = await startDumpServerProcess(TOTAL, CHUNK);
  const baselineMs = await new Promise((resolve) => {
    const t0 = performance.now();
    let received = 0;
    const sock = netMod.default.connect(basePort, '127.0.0.1', () => {});
    sock.on('data', (b) => { received += b.length; });
    sock.on('end', () => resolve(performance.now() - t0));
  });
  baseChild.kill();
  console.log(`[throughput] baseline (no bridge): ${(TOTAL / 1024 / 1024).toFixed(1)}MB in ${fmtMs(baselineMs)} = ${(TOTAL / 1024 / 1024 / (baselineMs / 1000)).toFixed(1)} MB/s`);

  // Bridged: every chunk crosses the SharedArrayBuffer + Atomics.wait bridge.
  const { child: bridgeChild, port: bridgePort } = await startDumpServerProcess(TOTAL, CHUNK);
  const t0 = performance.now();
  const handle = syncConnect('127.0.0.1', bridgePort);
  let received = 0, calls = 0;
  for (;;) {
    const chunk = syncRead(handle);
    calls++;
    if (chunk.length === 0) break;
    received += chunk.length;
  }
  const bridgedMs = performance.now() - t0;
  bridgeChild.kill();
  console.log(`[throughput] bridged: ${(received / 1024 / 1024).toFixed(1)}MB in ${calls} read() calls, ${fmtMs(bridgedMs)} = ${(received / 1024 / 1024 / (bridgedMs / 1000)).toFixed(1)} MB/s`);
  console.log(`[throughput] bridge overhead: ${(bridgedMs / baselineMs).toFixed(2)}x baseline time, ${fmtMs((bridgedMs - baselineMs) / calls)}/call amortized`);
  if (received !== TOTAL) console.log(`[throughput] MISMATCH: expected ${TOTAL}, got ${received}`);
}

shutdownBridge();
process.exit(0);
