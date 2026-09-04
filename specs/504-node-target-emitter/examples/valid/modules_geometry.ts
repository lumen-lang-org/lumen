export type Point = { x: number, y: number };
export const ORIGIN: Point = { x: 0, y: 0 };

export function distance(a: Point, b: Point): number {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  return Math.sqrt(dx * dx + dy * dy);
}

test("distance of the 3-4-5 triangle", () => {
  expect(distance(ORIGIN, { x: 3, y: 4 }) == 5.0);
});
