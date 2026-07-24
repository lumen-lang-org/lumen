// ResponseWriter.write takes a string chunk.
http.createServer(8080, (req: HttpRequest, res: ResponseWriter): void => {
  res.write(42);
  res.end();
});
