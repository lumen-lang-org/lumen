import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export function startDumpServerProcess(totalBytes, chunkSize) {
  const script = fileURLToPath(new URL('./dump_server_proc.mjs', import.meta.url));
  const child = spawn(process.execPath, [script, String(totalBytes), String(chunkSize)]);
  return new Promise((resolve, reject) => {
    let buf = '';
    child.stdout.on('data', (d) => {
      buf += d.toString();
      const m = buf.match(/PORT (\d+)/);
      if (m) resolve({ child, port: Number(m[1]) });
    });
    child.stderr.on('data', (d) => console.error('[dump_server_proc]', d.toString()));
    child.on('error', reject);
    child.on('exit', (code) => { if (code !== 0 && code !== null) console.error('[dump_server_proc] exited', code); });
  });
}
