// A different module's own type of the same name, used in this module's own
// annotations -- the case that used to resolve to the class above.
export type ApprovalGate = { limit: int };

export function defaultGate(): ApprovalGate {
  return { limit: 4 };
}
