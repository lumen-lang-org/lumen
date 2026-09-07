// Math.random() (this fixture's original example) was intentionally
// implemented since this fixture was written and is no longer a valid
// "unsupported std call" pin -- Math's whole standard set is covered now
// (lumen_check_stdlib.zig's mathCallType). Promise.race is a genuinely
// still-unsupported member of a different namespace, kept deliberately so
// (only Promise.resolve/all are implemented; compose with async/await
// instead) -- see the diagnostic's own wording.
async function main(): Promise<void> {
  let r = await Promise.race([Promise.resolve(1), Promise.resolve(2)]);
  console.log(`${r}`);
}
main();
