// A one-parameter handler must return a response record; returning void
// matches neither accepted signature.
http.createServer(8080, (req: HttpRequest): void => {
  console.log(req.path);
});
