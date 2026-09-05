// Types for editors and tsc: the Lumen standard library as this package
// provides it on Node. Numeric spellings collapse to `number` here, as in the
// root `lumen.d.ts`; the compiler enforces the real ones.
//
// Every namespace is a global once `@lumen-lang/node/globals` is imported
// (a Lumen program never imports its stdlib). Importing the package itself
// (`@lumen-lang/node`) gives the same names as exports and installs nothing.

type int = number;
type i32 = number;
type i64 = number;
type float = number;
type f64 = number;
type bool = boolean;

declare class ReadableStream {
  /** The next chunk (up to 64 KiB); "" at end of stream. */
  read(): string;
  /** The next line including its "\n"; "" only at end of stream. */
  readLine(): string;
  close(): void;
}

declare class WritableStream {
  write(chunk: string): void;
  close(): void;
}

declare class Buffer {
  static from(data: string, encoding?: "hex" | "base64" | string): Buffer;
  static alloc(n: int): Buffer;
  readonly length: int;
  toString(encoding: "hex" | "base64" | string): string;
  /** 0 outside the buffer. */
  at(i: int): int;
  /** Clamped to the buffer. */
  slice(start: int, end: int): Buffer;
  equals(other: Buffer): bool;
}

declare class Hash {
  update(data: Buffer): this;
  digest(): Buffer;
}
declare class Hmac extends Hash {}

declare class EventEmitter<T> {
  on(name: string, listener: (value: T) => void): void;
  once(name: string, listener: (value: T) => void): void;
  emit(name: string, value: T): void;
  removeAllListeners(name?: string): void;
  listenerCount(name: string): int;
}

declare namespace fs {
  function readFileSync(path: string, encoding?: string): string;
  function existsSync(path: string): bool;
  function realpathSync(path: string): string;
  function writeFileSync(path: string, data: string): void;
  function appendFileSync(path: string, data: string): void;
  function mkdirSync(path: string, recursive?: bool): void;
  function unlinkSync(path: string): void;
  function renameSync(from: string, to: string): void;
  function copyFileSync(from: string, to: string): void;
  function rmdirSync(path: string): void;
  function rmSync(path: string, recursive?: bool): void;
  function truncateSync(path: string, len: int): void;
  function linkSync(existing: string, link: string): void;
  function symlinkSync(target: string, path: string): void;
  function readlinkSync(path: string): string;
  function chmodSync(path: string, mode: int): void;
  function accessSync(path: string, mode?: int): bool;
  function cpSync(from: string, to: string, recursive?: bool): void;
  function mkdtempSync(prefix: string): string;
  function statSync(path: string): { size: int; isFile: bool; isDirectory: bool; mtimeMs: int };
  function lstatSync(path: string): { size: int; isFile: bool; isDirectory: bool; mtimeMs: int };
  function fstatSync(fd: int): { size: int; isFile: bool; isDirectory: bool; mtimeMs: int };
  function openSync(path: string, flags: "r" | "w" | "a" | string): int;
  function closeSync(fd: int): void;
  function readSync(fd: int, n: int): string;
  function writeSync(fd: int, data: string): int;
  function fchmodSync(fd: int, mode: int): void;
  function lchmodSync(path: string, mode: int): void;
  function fchownSync(fd: int, uid: int, gid: int): void;
  function chownSync(path: string, uid: int, gid: int): void;
  function lchownSync(path: string, uid: int, gid: int): void;
  function writevSync(fd: int, chunks: string[]): int;
  function readvSync(fd: int, sizes: int[]): string[];
  function fsyncSync(fd: int): void;
  function fdatasyncSync(fd: int): void;
  function ftruncateSync(fd: int, len: int): void;
  function futimesSync(fd: int, atimeMs: int, mtimeMs: int): void;
  function utimesSync(path: string, atimeMs: int, mtimeMs: int): void;
  function lutimesSync(path: string, atimeMs: int, mtimeMs: int): void;
  function readdirSync(path: string): string[];
  function watch(path: string, listener: (name: string, event: "change" | "rename") => void): void;
  function createReadStream(path: string): ReadableStream;
  function createWriteStream(path: string): WritableStream;
  function readFile(path: string): Promise<string>;
  function writeFile(path: string, data: string): Promise<void>;
  function appendFile(path: string, data: string): Promise<void>;
  function unlink(path: string): Promise<void>;
  function mkdir(path: string): Promise<void>;
  function rmdir(path: string): Promise<void>;
  function stat(path: string): Promise<{ size: int; isFile: bool; isDirectory: bool; mtimeMs: int }>;
}

declare namespace path {
  function basename(p: string, suffix?: string): string;
  function dirname(p: string): string;
  function extname(p: string): string;
  function normalize(p: string): string;
  function isAbsolute(p: string): bool;
  function join(...parts: string[]): string;
  function resolve(...parts: string[]): string;
  function parse(p: string): { root: string; dir: string; base: string; name: string; ext: string };
  function format(parts: { root: string; dir: string; base: string; name: string; ext: string }): string;
  function sep(): string;
  function delimiter(): string;
}

declare namespace os {
  function platform(): string;
  function arch(): string;
  function type(): string;
  function release(): string;
  function version(): string;
  function machine(): string;
  function hostname(): string;
  function endianness(): string;
  function tmpdir(): string;
  function homedir(): string;
  function EOL(): string;
  function devNull(): string;
  function uptime(): int;
  function totalmem(): int;
  function freemem(): int;
  function availableParallelism(): int;
  function loadavg(): f64[];
}

declare namespace process {
  function cwd(): string;
  function chdir(path: string): void;
  function sleep(ms: int): void;
  function exit(code: int): void;
  function env(key: string): string | null;
  function platform(): string;
  function arch(): string;
  function pid(): int;
  function argv(): string[];
  function uptime(): f64;
  function hrtime(): i64;
  function memoryUsage(): { rss: i64; vsize: i64 };
  function kill(pid: int, signal: string): bool;
  function umask(): int;
  function setUmask(mask: int): int;
  function getuid(): int;
  function getgid(): int;
  function geteuid(): int;
  function getegid(): int;
  function abort(): void;
  function version(): string;
  function stdin(): ReadableStream;
  function stdout(): WritableStream;
  function stderr(): WritableStream;
}

declare function argsCount(): int;
declare function arg(i: int): string;

declare namespace crypto {
  function randomBytes(n: int): string;
  function randomUUID(): string;
  function sha256(data: string): string;
  function sha1(data: string): string;
  function sha1Bytes(data: string): string;
  function base64Encode(data: string): string;
  function base64Decode(text: string): string;
  function randomKey(): string;
  function encrypt(plaintext: string, key: string): string;
  function decrypt(envelope: string, key: string): string;
  function randomBytesBuffer(n: int): Buffer;
  function hmacSync(key: Buffer, data: Buffer): Buffer;
  function encryptSync(key: Buffer, iv: Buffer, data: Buffer): Buffer;
  function decryptSync(key: Buffer, iv: Buffer, data: Buffer): Buffer;
  function pbkdf2Sync(password: Buffer, salt: Buffer, iterations: int, keylen: int): Buffer;
  function scryptSync(password: Buffer, salt: Buffer, keylen: int): Buffer;
  function timingSafeEqual(a: Buffer, b: Buffer): bool;
  function createHash(algorithm: string): Hash;
  function createHmac(algorithm: string, key: Buffer): Hmac;
}

declare namespace child_process {
  function spawnSync(command: string, args: string[]): { stdout: string; stderr: string; status: int };
  /** Needs the I/O broker of spec 508. */
  function spawn(command: string, args: string[]): never;
}

declare namespace net {
  /** Needs the I/O broker of spec 508. */
  function connect(host: string, port: int): never;
  function createServer(port: int, handler: (socket: unknown) => void): never;
}

declare namespace http {
  /** Needs the I/O broker of spec 508. */
  function request(url: string, method: string, body: string, headers: Map<string, string>): never;
  function get(url: string): never;
  function stream(url: string, method: string, body: string, headers: Map<string, string>): never;
  function createServer(port: int, handler: unknown): never;
  function METHODS(): string[];
  function STATUS_CODES(): Map<int, string>;
}

declare namespace zlib {
  function gzipSync(data: string): string;
  function gunzipSync(data: string): string;
  function deflateSync(data: string): string;
  function inflateSync(data: string): string;
}

declare namespace url {
  type Parts = { protocol: string; hostname: string; port: string; pathname: string; search: string; hash: string; href: string; query: Map<string, string> };
  function parse(s: string): Parts;
  function format(parts: Parts): string;
}

declare namespace time {
  function now(): i64;
  function monotonic(): i64;
}

declare namespace readline {
  function question(prompt: string): string;
}

declare namespace assert {
  function ok(cond: bool): void;
  function equal<T>(a: T, b: T): void;
}

declare namespace Worker {
  /** Needs the worker bridge of spec 508. */
  function run<T>(fn: () => T): Promise<T>;
}

interface Math {
  clamp(x: number, lo: number, hi: number): number;
  exp2(x: number): number;
}

interface StringConstructor {
  contains(s: string, sub: string): bool;
  startsWith(s: string, prefix: string): bool;
  isEmpty(s: string): bool;
  compare(a: string, b: string): int;
}

interface ArrayConstructor {
  isEmpty(a: unknown[]): bool;
}

interface NumberConstructor {
  parseInt(s: string, radix?: int): int | null;
  parseFloat(s: string): f64 | null;
}

interface JSON {
  parseOpen<T>(text: string): T;
}

interface Disposable {
  dispose(): void;
}
declare function defer(fn: () => void): Disposable;

declare function test(name: string, fn: () => void | Promise<void>): void;
interface Matchers<T> {
  toBe(expected: T): void;
  toEqual(expected: T): void;
}
declare function expect(condition: boolean): void;
declare function expect<T>(actual: T): Matchers<T>;
