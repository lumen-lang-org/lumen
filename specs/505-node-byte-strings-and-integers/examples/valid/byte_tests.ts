// Test blocks over byte strings and integers (spec 505 T011): what Joule's
// terminal tests assert, in miniature. The same file passes `lumen test`
// natively and `lumen test --target node` (spec 506).

// Terminal columns: decode UTF-8 from charCodeAt, the way Joule's
// visualWidth does, so a box-drawing character counts once.
function visualWidth(s: string): int {
  let width: int = 0;
  let i: int = 0;
  while (i < s.length) {
    const b: int = s.charCodeAt(i);
    if (b < 0x80) { i += 1; }
    else if (b < 0xe0) { i += 2; }
    else if (b < 0xf0) { i += 3; }
    else { i += 4; }
    width += 1;
  }
  return width;
}

type Frame = { type: string; text: string };

test("a string is its UTF-8 bytes on both targets", () => {
  expect("é".length).toBe(2);
  expect("héllo".length == 6);
  expect("héllo".charCodeAt(1)).toBe(195);
  expect(String.fromCharCode(104, 105)).toBe("hi");
  expect(String.fromCodePoint(233)).toBe("é");
  expect("héllo".toUpperCase()).toBe("HéLLO");
});

test("width is counted in columns, not in the bytes UTF-8 spends on them", () => {
  expect(visualWidth("abc")).toBe(3);
  expect(visualWidth("┌ · ┐")).toBe(5);
  expect("┌ · ┐".length > 5);
});

test("integer division truncates; number division does not", () => {
  const a: int = 7;
  const b: int = 2;
  const x: number = 7;
  expect(a / b).toBe(3);
  expect(x / 2).toBe(3.5);
  expect(-7 % 3).toBe(-1);
});

test("JSON round-trips non-ASCII text", () => {
  const f: Frame = { type: "text", text: "héllo ┌" };
  const back = JSON.parse<Frame>(JSON.stringify(f));
  expect(back.text).toBe("héllo ┌");
  expect(back.text.length).toBe(10);
});
