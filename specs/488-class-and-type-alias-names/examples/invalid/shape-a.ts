export type ApprovalGate = { limit: int };
export function gateA(): ApprovalGate { return { limit: 1 }; }
