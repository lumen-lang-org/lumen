// The concrete implementation, named after the shape it satisfies. It knows
// nothing about the module below.
export class ApprovalGate {
  mode: string;
  constructor(mode: string) { this.mode = mode; }
  describe(): string { return this.mode; }
}
