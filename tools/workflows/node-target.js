export const meta = {
  name: 'lumen-node-target',
  description: 'Implement the Node target specs (502-507) slice by slice: implement, gate, review, fix; then the Joule-side spec 004; commits to the current branch after every green slice',
  whenToUse: 'Long-running autonomous implementation of specs/50x-node-*. Pass args {specs: [...], maxRounds, joule: "/path/to/joule", skipJoule: true} to narrow it.',
  phases: [
    { title: 'Preflight', detail: 'toolchain, branch, baseline gate' },
    { title: 'Implement', detail: 'per spec: implement -> gate -> review -> fix, until tasks.md is all ticked and the gate is green' },
    { title: 'Joule', detail: 'joule-sh/code spec 004: string fixes, shim twins, node-test sweep' },
    { title: 'Report', detail: 'full gate and STATUS.md' },
  ],
}

// ---- configuration -------------------------------------------------------
const LUMEN = (args && args.lumen) || '/home/user/lumen'
const JOULE = (args && args.joule) || '/home/user/code'
const BRANCH = (args && args.branch) || 'claude/lumen-node-gs-runtime-2zo9sk'
const MAX_ROUNDS = (args && args.maxRounds) || 6
const FULL_CORPUS = !(args && args.fullCorpus === false)
const QUICK_CORPUS = 'the manifests of specs 001 and 502-507 only, each via the conformance runner binary (find it under .zig-cache with `find .zig-cache -type f -name lumen-conformance`; `zig build conformance` builds it)'
const SPECS = (args && args.specs) || [
  '502-string-literal-newline',
  '503-node-runtime-package',
  '504-node-target-emitter',
  '505-node-byte-strings-and-integers',
  '506-node-test-runner',
  '507-node-ffi-link',
]

const ENV = `Environment: run \`cd ${LUMEN} && sh tools/node-target-env.sh\` once (idempotent; installs Zig 0.16, seeds libxev, fixes libgc) and then prefix every shell command with \`export PATH=$HOME/.zig:$PATH\`. Node 22 is at /opt/node22/bin. Work on branch ${BRANCH} in ${LUMEN}; never switch branches. Commit messages are plain: no Co-Authored-By, no AI attribution, no model names (repo rule in CLAUDE.md).`

const RULES = `Read ${LUMEN}/CLAUDE.md first and obey "Fix the Cause, Not the Symptom": never work around a compiler limitation in a package or example; never migrate fixtures to make a suite pass; never skip or weaken a test. Read docs/CODEMAP.md before grepping. The spec folder's spec.md is the contract, plan.md the map, tasks.md the checklist: tick tasks in tasks.md as you complete them (edit the file), and add a task if you discover work the list is missing.`

const GATE = `The gate is, from ${LUMEN}: \`zig build\` (compiler builds), \`zig build test\` (unit tests), the spec's own manifest via the conformance runner (\`R=$(find .zig-cache -type f -name lumen-conformance | head -1); $R specs/<spec>/conformance/manifest.json zig-out/bin/lumen\` — build it with \`zig build conformance\` once if absent), and \`zig fmt --check src tools build.zig\`. \`zig build conformance\` (the whole corpus, ~30 min) runs at the end of each spec, not each round.`

const IMPL_SCHEMA = {
  type: 'object',
  properties: {
    tasksDone: { type: 'array', items: { type: 'string' } },
    tasksLeft: { type: 'array', items: { type: 'string' } },
    gate: { type: 'object', properties: { build: { type: 'boolean' }, test: { type: 'boolean' }, manifest: { type: 'boolean' }, fmt: { type: 'boolean' } }, required: ['build', 'test', 'manifest', 'fmt'] },
    commit: { type: 'string', description: 'short hash of the last commit made this round, or empty' },
    blocked: { type: 'string', description: 'empty unless the remaining work needs a decision only a human can make; say exactly what' },
    notes: { type: 'string' },
  },
  required: ['tasksDone', 'tasksLeft', 'gate', 'commit', 'blocked', 'notes'],
}

const GATE_SCHEMA = {
  type: 'object',
  properties: {
    pass: { type: 'boolean' },
    failures: { type: 'array', items: { type: 'string' }, description: 'each failing command with the decisive lines of its output' },
  },
  required: ['pass', 'failures'],
}

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' }, line: { type: 'integer' },
          blocking: { type: 'boolean', description: 'true only if the spec is violated, a test is weakened, or CLAUDE.md "fix the cause" is broken' },
          summary: { type: 'string' }, evidence: { type: 'string' },
        },
        required: ['file', 'blocking', 'summary', 'evidence'],
      },
    },
  },
  required: ['findings'],
}

// ---- preflight -------------------------------------------------------------
phase('Preflight')
const pre = await agent(`${ENV}\n\nVerify the environment for autonomous work and report. Check: zig 0.16.0 on PATH after the env script; \`zig build\` succeeds; \`cd /tmp && printf 'console.log("hi")' > p.ts && ${LUMEN}/zig-out/bin/lumen run p.ts\` prints hi; node >= 22.18; git in ${LUMEN} is on ${BRANCH} with a clean tree and origin reachable (\`git fetch origin ${BRANCH}\`); ${JOULE} exists and is on ${BRANCH}. Run \`zig build test\` and report pass/fail. Then, if ${LUMEN}/specs/501-node-runtime/corpus_baseline.txt does not exist, run \`zig build conformance\` (30+ minutes: run it in the background, poll its log, use a long timeout) and write every FAIL line of its output, sorted, to that file — these are failures that predate the Node work and are not this run's to fix — then commit it with the plain message "spec 501: conformance baseline before the Node target" and push. That file is the only thing you may change.`, {
  label: 'preflight', effort: 'low',
  schema: { type: 'object', properties: { ok: { type: 'boolean' }, problems: { type: 'array', items: { type: 'string' } } }, required: ['ok', 'problems'] },
})
if (!pre || !pre.ok) {
  log('preflight failed: ' + JSON.stringify(pre && pre.problems))
  return { stopped: 'preflight', problems: pre ? pre.problems : ['preflight agent died'] }
}

// ---- implement, spec by spec ----------------------------------------------
phase('Implement')
const results = []
for (const spec of SPECS) {
  const dir = `${LUMEN}/specs/${spec}`
  let carry = ''          // failures and blocking findings from the previous round
  let outcome = { spec, rounds: 0, done: false, blocked: '', commits: [] }
  for (let round = 1; round <= MAX_ROUNDS; round++) {
    if (budget.total && budget.remaining() < 150_000) { log('budget nearly spent; stopping before ' + spec + ' round ' + round); outcome.blocked = 'budget'; break }
    outcome.rounds = round
    log(`${spec}: round ${round}`)

    const impl = await agent(`${ENV}\n\n${RULES}\n\n${GATE}\n\nYou are implementing spec ${spec} (${dir}/spec.md, plan.md, tasks.md), round ${round} of at most ${MAX_ROUNDS}. Do the unticked tasks in order, as many as you can finish properly this round; a task is finished when its code, its test or conformance case, and its doc line exist and the gate passes. ${carry ? 'Start from this feedback on the previous round and fix its causes first:\n' + carry + '\n\n' : ''}Before committing: run the gate; if a gate command fails, fix the cause (not the test). Commit each coherent step with a plain message that names the spec (e.g. "spec ${spec.slice(0, 3)}: ..."); push with \`git push -u origin ${BRANCH}\` (retry with backoff on network errors). If the gate is red at the end of your budget, do not commit the red state; leave the tree clean with \`git stash\` and report what fails. Report precisely: tasks done, tasks left, gate results, last commit, and whether anything needs a human decision.`, {
      label: `impl:${spec.slice(0, 3)}#${round}`, phase: 'Implement', effort: 'high', schema: IMPL_SCHEMA,
    })
    if (!impl) { carry = 'the previous implementation agent died before reporting; re-check git status and continue'; continue }
    if (impl.commit) outcome.commits.push(impl.commit)
    if (impl.blocked) { outcome.blocked = impl.blocked; log(`${spec}: blocked — ${impl.blocked}`); break }

    // independent gate + two review lenses, concurrently (read-only)
    const [gate, correctness, causes] = await parallel([
      () => agent(`${ENV}\n\n${GATE}\n\nRun the gate for spec ${spec} exactly as listed and report the truth. Also run \`node --test packages/node-runtime/tests/\` if that directory exists. Do not fix anything, do not change files.`, { label: `gate:${spec.slice(0, 3)}#${round}`, phase: 'Implement', effort: 'low', schema: GATE_SCHEMA }),
      () => agent(`${RULES}\n\nReview the work committed on ${BRANCH} for spec ${spec} (\`git log --oneline origin/main..HEAD -- . \` and \`git diff origin/main...HEAD\` in ${LUMEN}, restricted to what this spec touches) against ${dir}/spec.md through the correctness lens: does each FR hold, does each conformance case pin what the spec says, are the Zig/wasm targets untouched (compare generated Zig for two corpus programs before and after if the emitter was touched)? Try to refute the claim that the spec is satisfied. Report only what you verified by reading or running; mark blocking only for a spec violation. Do not change files.`, { label: `review-correctness:${spec.slice(0, 3)}#${round}`, phase: 'Implement', effort: 'high', schema: REVIEW_SCHEMA }),
      () => agent(`${RULES}\n\nReview the same diff (\`git diff origin/main...HEAD\` in ${LUMEN}, what spec ${spec} touches) through the CLAUDE.md lens: any workaround in an example/package instead of a fix in the compiler, any fixture migrated to make a suite pass, any weakened or skipped test, any symptom-level fix (a better message for a wrong rule), any missing tasks.md tick or codemap regeneration (\`sh tools/codemap.sh\` must leave docs/CODEMAP.md unchanged). Mark blocking only for those categories. Do not change files.`, { label: `review-causes:${spec.slice(0, 3)}#${round}`, phase: 'Implement', effort: 'medium', schema: REVIEW_SCHEMA }),
    ])
    const findings = [correctness, causes].filter(Boolean).flatMap(r => r.findings).filter(f => f.blocking)
    const gateOk = !!(gate && gate.pass)
    const tasksLeft = impl.tasksLeft || []
    log(`${spec}: gate ${gateOk ? 'green' : 'RED'}, ${tasksLeft.length} tasks left, ${findings.length} blocking findings`)
    if (gateOk && tasksLeft.length === 0 && findings.length === 0) { outcome.done = true; break }
    carry = [
      gateOk ? '' : 'GATE FAILURES:\n' + (gate ? gate.failures.join('\n') : 'gate agent died; re-run it yourself'),
      findings.length ? 'BLOCKING REVIEW FINDINGS:\n' + findings.map(f => `- ${f.file}${f.line ? ':' + f.line : ''}: ${f.summary} — ${f.evidence}`).join('\n') : '',
      tasksLeft.length ? 'TASKS LEFT: ' + tasksLeft.join('; ') : '',
    ].filter(Boolean).join('\n\n')
  }
  if (!outcome.done && !outcome.blocked) outcome.blocked = `not finished after ${MAX_ROUNDS} rounds`

  // full corpus once per spec, so a regression is caught before the next spec builds on it
  const full = await agent(`${ENV}\n\nIn ${LUMEN} run ${FULL_CORPUS ? '\`zig build conformance\` (hours in a small container; run it in the background with nohup, poll the log, use a long timeout)' : QUICK_CORPUS} and, if tools/emit_snapshot.sh exists, the emit snapshot diff. Compare the FAIL lines with ${LUMEN}/specs/501-node-runtime/corpus_baseline.txt: pass means no FAIL line that is absent from the baseline (a case in the baseline may fail; a case fixed since is fine). Report the new failures verbatim. Do not change files.`, { label: `corpus:${spec.slice(0, 3)}`, phase: 'Implement', effort: 'low', schema: GATE_SCHEMA })
  outcome.corpus = full ? (full.pass ? 'green' : 'RED: ' + full.failures.join(' | ')) : 'unknown'
  if (full && !full.pass) {
    const fix = await agent(`${ENV}\n\n${RULES}\n\n${GATE}\n\nThe full conformance corpus has failures that are not in specs/501-node-runtime/corpus_baseline.txt after spec ${spec}:\n${full.failures.join('\n')}\n\nFind the cause in this spec's commits (git log on ${BRANCH}), fix it properly, re-run the failing manifests and \`zig build test\`, commit and push. Report.`, { label: `corpus-fix:${spec.slice(0, 3)}`, phase: 'Implement', effort: 'high', schema: IMPL_SCHEMA })
    outcome.corpus = fix && fix.gate.test && fix.gate.manifest ? 'green after fix ' + fix.commit : 'STILL RED'
  }
  results.push(outcome)
  log(`${spec}: ${outcome.done ? 'done' : 'stopped (' + outcome.blocked + ')'}; corpus ${outcome.corpus}`)
  if (outcome.blocked === 'budget') break
}

// ---- Joule ------------------------------------------------------------------
let joule = null
if (!(args && args.skipJoule) && results.some(r => r.done)) {
  phase('Joule')
  const emitterDone = results.find(r => r.spec.startsWith('504') && r.done)
  joule = await agent(`${ENV}\n\nNow work in ${JOULE} on branch ${BRANCH} (joule-sh/code), spec ${JOULE}/specs/004-node-runtime/spec.md. Its Makefile invokes \`lumen\`; use ${LUMEN}/zig-out/bin/lumen (put it on PATH). Do T001 (fix the five raw-newline literals; \`make test\` must stay green — it needs \`make\` to build the C shims with cc first) and, ${emitterDone ? 'since the Node emitter exists, T002 and T003 as far as specs 506/507 allow; produce node-skip.txt with a reason per skipped test' : 'since the Node emitter is not done, only T001'}. Also run ${LUMEN}/specs/501-node-runtime/probe/run_tests.mjs from ${JOULE} before and after and record both summary lines in specs/004-node-runtime/spec.md under a "Measured" heading. Commit with plain messages; push with \`git push -u origin ${BRANCH}\`. Report.`, { label: 'joule:004', phase: 'Joule', effort: 'high', schema: IMPL_SCHEMA })
}

// ---- final full corpus when the per-spec checks were quick ------------------
let finalCorpus = null
if (!FULL_CORPUS && results.some(r => r.done)) {
  phase('Report')
  finalCorpus = await agent(`${ENV}\n\nIn ${LUMEN} run \`zig build conformance\` (hours: nohup in the background, poll the log, long timeout). Compare FAIL lines with specs/501-node-runtime/corpus_baseline.txt; pass means no failure absent from the baseline. Report new failures verbatim. Do not change files.`, { label: 'corpus:final', phase: 'Report', effort: 'low', schema: GATE_SCHEMA })
}

// ---- report -----------------------------------------------------------------
phase('Report')
const summary = await agent(`${ENV}\n\nWrite ${LUMEN}/specs/501-node-runtime/STATUS.md: for each of ${JSON.stringify(SPECS)} the state of its tasks.md (ticked/total), the last commit touching it, the gate state, and the blockers below verbatim; then the Joule result. Data:\n${JSON.stringify({ results, joule, finalCorpus }, null, 2)}\n\nVerify each claim against git and the files before writing it (read tasks.md, run \`git log --oneline\`). Commit "spec 501: status after autonomous run" and push. Return the file's text.`, { label: 'status', phase: 'Report', effort: 'medium' })

return { results, joule: joule && { tasksDone: joule.tasksDone, tasksLeft: joule.tasksLeft, blocked: joule.blocked }, finalCorpus, status: summary }
