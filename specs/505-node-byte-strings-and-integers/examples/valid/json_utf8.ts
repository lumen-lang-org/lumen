// FR-005: JSON.stringify and JSON.parse<T> round-trip non-ASCII text
// identically on both targets: a string is its UTF-8 bytes, a `\uXXXX`
// escape in a document decodes to those bytes.
type Item = { name: string, tags: string[], n: number };
const item: Item = { name: "café", tags: ["naïve", "日本"], n: 1.5 };
const doc = JSON.stringify(item);
console.log(doc);
console.log(doc.length);
const back = JSON.parse<Item>(doc);
console.log(back.name.length, back.tags[1].length, back.n);
const escaped = JSON.parse<Item>("{\"name\":\"caf\\u00e9\",\"tags\":[\"\\ud83d\\ude80\"],\"n\":2}");
console.log(escaped.name == "café", escaped.tags[0].length, escaped.tags[0]);
console.log(JSON.stringify(escaped));
