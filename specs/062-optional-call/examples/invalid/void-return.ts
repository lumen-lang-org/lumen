// A void-returning optional closure has no meaningful `?void` -- rejected,
// matching spec 052's own precedent for `a?.b()` on a void method.
type Cb = () => void;

function run(cb: Cb | null): void {
  cb?.();
}
