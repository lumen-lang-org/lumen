// A decorator on a function: it receives the parameters and the return type as
// they were written, not as the checker resolves them.

import { Signature } from "./signature.ts";

export type DecoratorUse = {
  name: string,
  args: string[],
};

export type ParamDescription = {
  name: string,
  type: string,
  decorators: DecoratorUse[],
};

export type Description = {
  protocol: int,
  kind: string,
  name: string,
  args: string[],
  file: string,
  line: int,
  params: ParamDescription[],
  returns: string,
};

export function signatureOf(d: Description): Signature {
  let params = "";
  let i: int = 0;
  while (i < d.params.length) {
    if (i > 0) { params = params + ","; }
    params = params + d.params[i].name + ":" + d.params[i].type;
    if (d.params[i].decorators.length > 0) {
      params = params + "@" + d.params[i].decorators[0].name;
    }
    i = i + 1;
  }
  let s: Signature = { name: d.args[0], params: params, returns: d.returns };
  return s;
}
