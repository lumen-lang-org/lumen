import { greet } from "./greet-lib.ts";

export function loud(name: string): string {
  return greet(name).toUpperCase();
}
