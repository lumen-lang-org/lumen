// Runs as its own OS process, so it can never be affected by the caller's
// synchronous Atomics.wait -- matching a real peer (an API server, a daemon),
// which is never the same thread, or even the same process, as the blocked
// caller. Reads totalBytes/chunkSize from argv, listens on an ephemeral
// port, prints "PORT <n>" once ready, then streams that many bytes to every
// connection and exits after serving one.
import net from 'node:net';
const totalBytes = Number(process.argv[2]);
const chunkSize = Number(process.argv[3]);
const server = net.createServer((sock) => {
  const chunk = Buffer.alloc(chunkSize, 0x61);
  let sent = 0;
  function pump() {
    while (sent < totalBytes) {
      const n = Math.min(chunkSize, totalBytes - sent);
      const ok = sock.write(n === chunkSize ? chunk : chunk.subarray(0, n));
      sent += n;
      if (!ok) { sock.once('drain', pump); return; }
    }
    sock.end();
  }
  pump();
  sock.on('close', () => server.close());
});
server.listen(0, '127.0.0.1', () => {
  console.log('PORT ' + server.address().port);
});
