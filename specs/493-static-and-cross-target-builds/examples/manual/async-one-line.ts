// The reproduction from issue #37. One `setTimeout` is enough to route the
// compile through the backend's module form (`--dep xev -Mroot=... -Mxev=...`),
// which is the form a response file of link flags could not reach. Built with
// `lumen compile --static async-one-line.ts`; prints `hi`.
setTimeout(() => { console.log("hi"); }, 1);
