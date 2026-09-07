import { workspaceRoot as currentWorkspaceRoot } from "./a.ts";

// The alias exists specifically so this local can be named the same as the
// plain export -- exactly attach.ts's own reason for it.
export function first(): string {
  return currentWorkspaceRoot();
}

export function second(): string {
  let workspaceRoot: string = currentWorkspaceRoot();
  return workspaceRoot;
}

console.log(first());
console.log(second());
