import http from "node:http";
const body = "Hello, World!";
http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end(body);
}).listen(8082, () => {});
