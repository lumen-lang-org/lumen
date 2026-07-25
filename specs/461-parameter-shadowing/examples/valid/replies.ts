// A tiny module in the shape of a web package: it exports `json`, an ordinary
// word, as a function.
export function json(status: int, body: string): string {
  return `${status} ${body}`;
}

export function ok(body: string): string {
  return json(200, body);
}
