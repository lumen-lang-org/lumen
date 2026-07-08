// `?.()` requires the UNWRAPPED type to be a `func_type`, not just any
// nullable value -- narrower than `a?.b`/`a?.[i]`'s "any nullable value".
let y: int | null = 5;
y?.();
