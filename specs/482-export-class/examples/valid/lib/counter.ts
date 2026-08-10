export class Counter {
  n: int;
  constructor(start: int) { this.n = start; }
  bump(by: int): int { this.n = this.n + by; return this.n; }
}

export interface Named { name: string }

export enum Colour { Red, Green }

export function greet(who: string): string { return "hello " + who; }
