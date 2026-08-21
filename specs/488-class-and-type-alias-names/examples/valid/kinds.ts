// The value side of the clash need not be a class: an enum, a function and a
// binding all claim a name the same way.
export enum Node { One = 1 }

export function nodeValue(): int {
  return Node.One;
}
