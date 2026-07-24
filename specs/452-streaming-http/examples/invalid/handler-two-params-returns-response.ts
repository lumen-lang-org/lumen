// A two-parameter handler must return void; returning a response record
// matches neither accepted signature.
http.createServer(8080, (req: HttpRequest, res: ResponseWriter): HttpResponse => {
  return { status: 200, body: "x", ok: true, headers: new Map<string, string>() };
});
