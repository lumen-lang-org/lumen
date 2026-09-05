// `url.*` (specs 036, 045). `parse` follows the native runtime's grammar
// (std.Uri: `scheme ":" ["//" authority] path ["?" query] ["#" fragment]`),
// so the fields are the raw components — no lowercasing, no default-port
// elision, `href` is the input verbatim — and a string without a scheme
// parses to the empty record with `pathname` "/". `query` is `search`
// split into a Map, without percent-decoding.
const URI = /^([A-Za-z][A-Za-z0-9+.-]*):(?:\/\/(?:([^@/?#]*)@)?(\[[^\]]*\]|[^:/?#]*)(?::([0-9]*))?)?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/s;

function parseQuery(search) {
  const map = new Map();
  const q = search.startsWith("?") ? search.slice(1) : search;
  for (const pair of q.split("&")) {
    if (pair.length === 0) continue;
    const eq = pair.indexOf("=");
    if (eq < 0) continue;
    map.set(pair.slice(0, eq), pair.slice(eq + 1));
  }
  return map;
}

export function parse(str) {
  const m = URI.exec(str);
  if (!m) {
    return { protocol: "", hostname: "", port: "", pathname: "/", search: "", hash: "", href: str, query: new Map() };
  }
  const [, scheme, , host, port, path, query, fragment] = m;
  const search = query === undefined ? "" : "?" + query;
  return {
    protocol: scheme + ":",
    hostname: host ?? "",
    port: port ?? "",
    pathname: path.length === 0 ? "/" : path,
    search,
    hash: fragment === undefined ? "" : "#" + fragment,
    href: str,
    query: parseQuery(search),
  };
}

export function format(parts) {
  const hostPort = parts.port.length > 0 ? `${parts.hostname}:${parts.port}` : parts.hostname;
  return `${parts.protocol}//${hostPort}${parts.pathname}${parts.search}${parts.hash}`;
}
