---
description: Continuous-loop task driver. Runs multiple generations until target met, plateau-ladder exhausted, sentinel stop, or max-gen cap. Usage /orchestrate <task-id> [--max-gens N] [--target-metric X]
argument-hint: "[task-id] [--max-gens N] [--target X]"
---

You drive `$1` to completion across MULTIPLE generations. NOT one-shot. Loop until exhausted or stopped. Subagents in Claude Code GUI cannot spawn other subagents, so the outer loop runs HERE in main context.

## Stop conditions (check at top of every generation loop)

1. **Target met:** verify command output meets `Target:` in `bench/tasks/$1.md` (if specified) or user-passed `--target`. STOP exhausted-success.
2. **Sentinel stop:** `workspace/$1-stop.md` exists. STOP user-requested.
3. **Plateau ladder exhausted:** STOP plateaued ONLY after the meta-improver has hit 2 consecutive scaffold rejects (see "Meta-improver escalation"). A generation that finds NO local improvement is NOT a plateau by itself: it is that generation's REJECT and must feed the EXPLOIT->REFINE->PIVOT ladder and the 3-strike meta-improver escalation (see outer-loop reject branch). Do NOT self-stop merely because "the current engine found no gain" -- that is the signal to PIVOT, not to quit.
4. **Max gens reached:** default 20 outer generations. Override with `--max-gens N`. STOP cap.
5. **5-hour Claude Pro window warning:** if you've run >15 generations and tokens-used is high, write `workspace/$1-status.md` with "approaching window limit, recommend resume in next session" and STOP.

## Outer loop (you run this in main context)

```
GEN := highest existing gen-NNNN for this task_id in archive + 1
AGENT := 1
PRIOR_BASELINE := original $BASELINE captured at first /orchestrate call
LAST_PROMOTED := latest archive/gen-MMMM/agent-PPPP/manifest.json#commit_after for this task_id (or PRIOR_BASELINE if none)
CONSECUTIVE_REJECTS := 0
EXPERIMENTS_TRIED := [list from past archive manifests with this task_id]

loop:
  check stop conditions above
  if any STOP: write workspace/$1-status.md with summary; print one-line; exit

  BASELINE := LAST_PROMOTED  # each gen rebases on last promoted commit, not original
  GEN_CONFIG := build_config(GEN, AGENT, BASELINE, EXPERIMENTS_TRIED, LESSONS_FILTERED)

  run_single_generation(GEN_CONFIG)  # Steps 1-7 below

  if promoted by host runner (poll archive/gen-<GEN>/agent-<AGENT>/ within 60s):
    LAST_PROMOTED := new HEAD
    CONSECUTIVE_REJECTS := 0
    EXPERIMENTS_TRIED += this experiment description
    GEN += 1; AGENT := 1
  elif rejected OR local-no-improvement (the engine/coder produced no metric gain this gen, so nothing was staged):
    # CRITICAL: "my current engine found no gain" is NOT a stop -- it is this generation's REJECT.
    CONSECUTIVE_REJECTS += 1
    EXPERIMENTS_TRIED += this experiment (mark FAILED)
    AGENT += 1
    if CONSECUTIVE_REJECTS >= 3:
      dispatch meta-improver subagent to propose scaffold/engine change (one-shot, not loop)
      # the meta-improver is the designed path for "need a genuinely NEW capability"
      # (e.g. C-level GA, PERM/nPERMis chain-growth, new move class) -- use it instead of
      # handing back to the operator with "needs new engine first".
      CONSECUTIVE_REJECTS := 0
      # next gen tries again with new scaffold/engine
    continue loop   # do NOT self-stop; only the real stop conditions above end the loop

continue loop
```

## Single-generation steps (inside one loop iteration)

### Step 1: Read task spec + memory
```
Read bench/tasks/$1.md
# If bench/tasks/$1.md is ABSENT, the spec often lives at workspace/$1/TASK.md.
# workspace/ is gitignored -> git-grep/tracked search will NOT find it; list/read the
# workspace/$1/ dir directly. Do NOT conclude "no spec exists" until you check there.
Read all archive/gen-*/agent-*/manifest.json filtered by task_id == "$1" -> EXPERIMENTS_TRIED list
Read LESSONS.md, grep for "$1" or "Source:.*gen-NNNN" where gen-NNNN matched this task -> LESSONS_FILTERED
Read archive/rejected/<last-N>/rejection.txt -> recent failure modes for this task
```

### Step 2: Idempotency check
Run task's `Verify:` command. If metric already at target → STOP exhausted-success.

### Step 3: Capture baseline (NOT original)
```bash
BASELINE=$(git rev-parse HEAD)   # this is LAST_PROMOTED, not the very first
```
Each generation builds on prior promoted work. Diff is gen-relative, not run-relative.

### Step 4: Dispatch specialists with memory context
Pass to coder + planner:
- `Baseline: <SHA>`
- `Generation: <GEN>`
- `Agent: <AGENT>`
- `ExperimentsTried:` — bulleted list from EXPERIMENTS_TRIED, marked SUCCESS/FAILED
- `LessonsContext:` — relevant LESSONS.md entries
- `RecentFailures:` — last 3 rejection reasons if any

Specialist chain per generation (sequential, no fan-out except tester):

1. **researcher** (Haiku) — skip if EXPERIMENTS_TRIED already has >=3 entries (sufficient context). Otherwise one-page brief.

2. **planner** (Sonnet) — MUST consume EXPERIMENTS_TRIED + LESSONS_FILTERED. Output `workspace/$1/plan-gen<N>.md` with ranked experiments that EXTEND successful directions or AVOID failed ones. Use plateau ladder hints:
   - EXPLOIT: latest success + small perturbation
   - REFINE: try parameter sweep around latest success
   - PIVOT: radically different angle (analogical prompting, constraint inversion)
   - Pick mode based on CONSECUTIVE_REJECTS: 0=EXPLOIT, 1=REFINE, 2+=PIVOT

3. **coder** (Sonnet) — runs autoresearch inner loop. Pass `Iterations:` from task spec (default 15-30 per generation). Coder MUST verify before staging.

4. **tester** (Haiku, optional, up to 5 parallel) — only if planner flagged coverage gaps.

5. **reviewer** (Sonnet) — APPROVE/REWORK/REJECT + 6-check audit. On REWORK, loop coder ONCE within this generation (do NOT count as separate gen).

### Step 5: Verify staged artifacts
Inspect `agenta\infra\staged/gen-<GEN>/agent-<AGENT>/`. If missing fields or `verify_exit_code != 0`: do not hand to host; loop back to coder once OR mark this generation REJECT (don't stage at all) + go to next gen.

**Local-no-improvement is a REJECT, not a STOP.** If the coder/engine ran but produced no metric gain over LAST_PROMOTED (nothing worth staging), do NOT write STOPPED_PLATEAU and exit. Take the `elif ... local-no-improvement` branch in the outer loop: increment CONSECUTIVE_REJECTS, mark the experiment FAILED, bump AGENT, and CONTINUE. The planner escalates EXPLOIT(0)->REFINE(1)->PIVOT(2+), and at 3 the meta-improver builds a genuinely new engine/scaffold capability. Only the real stop conditions (target / sentinel / cap / window / meta-improver double-reject) end the loop.

### Step 6: Archivist (MANDATORY every generation)
Dispatch archivist to write 1-3 lessons into `agenta\infra\lessons-inbox/<gen>-<agent>-<n>.md`. Host runner appends to LESSONS.md within 30s. **CRITICAL** for cross-generation learning: without this, next gen's planner sees no new lessons.

### Step 7: Poll archive (wait up to 60s for host promotion)
```
for 60s:
  if archive/gen-<GEN>/agent-<AGENT>/ exists → PROMOTED, break
  if archive/rejected/gen-<GEN>-agent-<AGENT>*/ exists → REJECTED, break
  sleep 5s
```
Update LAST_PROMOTED if promoted. Increment CONSECUTIVE_REJECTS if rejected.

### Step 8: Print generation summary, continue loop
```
gen-<N>/agent-<M>: <verdict> metric <before> -> <after>, consecutive_rejects=<R>, experiments_tried=<E>
```

## Status file (overwrite each iteration)

Write to `workspace/$1-status.md` at end of every generation:
```markdown
# Loop status: $1
Last update: <iso>
Current generation: <GEN>
Generations completed: <successful promotions>
Consecutive rejects: <R>
Latest metric: <value>
Best metric: <best ever for this task>
Experiments tried: <count>
Status: RUNNING | STOPPED_SUCCESS | STOPPED_PLATEAU | STOPPED_CAP | STOPPED_USER | STOPPED_WINDOW

## Recent experiments
<bulleted last 5>
```

Operator reads this between sessions to see progress.

## Meta-improver escalation

When CONSECUTIVE_REJECTS >= 3:
1. Dispatch `meta-improver` subagent ONCE (not in loop)
2. Pass it `EXPERIMENTS_TRIED`, `RecentFailures`, the LESSONS context
3. Meta-improver proposes ONE scaffold mutation, stages it as `scaffold-edit` category
4. Host promotes scaffold edit through tier 1-2 + tier 7 only
5. Reset CONSECUTIVE_REJECTS to 0
6. Continue loop with patched scaffold next iteration

If meta-improver itself plateaus (2 consecutive scaffold rejects), STOP plateaued.

## How user controls the loop

| Action | File / command |
|---|---|
| Graceful stop after current gen | `echo > workspace/$1-stop.md` |
| Check progress | `cat workspace/$1-status.md` |
| Hard stop | Ctrl-C the Claude session (loses progress in current gen only) |
| Resume after stop | run `/orchestrate $1` again — picks up from last LAST_PROMOTED automatically |

## Lessons-driven new directions

The planner MUST extend or pivot based on LESSONS_FILTERED. Heuristics:

- If a lesson says "X approach failed because Y" — don't repeat X, look for Y-avoiding alternatives
- If a lesson says "tuning param P from A to B improved metric" — try P=C, P=D in parameter sweep
- If 5+ lessons all about same subsystem — flag this as architectural ceiling, recommend meta-improver
- If lessons mention a verification technique not yet used — apply it next gen (e.g. add property test for invariant X)

Pass an explicit `NewDirectionsCandidate:` block to planner with 3-5 derived suggestions from LESSONS_FILTERED.

## Resource budget per call

Default per `/orchestrate` invocation: max 20 outer generations, 5-hour Claude Pro window soft-cap. Hard-cap monitor: if outer loop has run >15 generations OR session age >4h, write status STOPPED_WINDOW and exit gracefully. User resumes by running `/orchestrate $1` again in next session — loop reads archive state and picks up.

## When NOT to use loop mode

- One-off bench task with target already nearly met (use idempotency-check fast-exit at Step 2)
- Scaffold edit (`/dgm-improve` instead — that command is purpose-built single-shot)
- Pure research/recon (`/orchestrate $1 --max-gens 1` for explicit one-shot)


## Flow discipline (gen-0042 lessons â€” MANDATORY)

### Reviewer dispatch â€” ALWAYS require review.json write

When dispatching the reviewer subagent, the prompt MUST instruct it to write `agenta/infra/staged/<gen>/<agent>/review.json` with the full verdict block. **NEVER** tell reviewer "report only", "narrate verdict", "summarize in response", or anything that lets it skip the file write. Without the file, host's tier-0 review-gate times out after 10min and REJECTS even a clean diff.

Reviewer subagent has the `Write` tool. Reviewer.md prompt instructs it to write the file. Your orchestrator dispatch prompt should reinforce this:

> "Write your verdict block to `agenta/infra/staged/<gen>/<agent>/review.json` per reviewer.md schema. Do NOT just narrate the verdict in your response â€” the host's review-gate reads the file."

### Restage flow â€” ALWAYS re-capture verify.log

When restaging the same diff to a fresh `agent-NNNN` directory (e.g. recovering from a missing-artifact rejection), the staged dir MUST contain ALL of:
- `diff.patch`
- `manifest.json`
- `baseline.txt`
- `verify.log`  â† FREQUENTLY FORGOTTEN
- `results.tsv`
- `review.json` (reviewer writes; don't pre-create)
- `scores.json`

If you copy only diff.patch + manifest.json, host's tier 1-2 manifest schema check rejects with `manifest incomplete or unverified` even though the diff itself is fine.

**Restage script template:**

`ash
GEN=0042
AGENT=0003  # next available
SRC_AGENT=0001  # source of diff
DST=agenta/infra/staged/gen-/agent-
mkdir -p 
# Re-capture verify.log fresh (don't trust stale copies)
cd workspace/<task>
<verify_command> > /verify.log 2>&1
echo "EXIT=True" >> /verify.log
# Re-generate diff against baseline
git diff --binary --full-index ..HEAD > /diff.patch
echo  > /baseline.txt
# Re-write manifest with bumped agent number
# Re-write results.tsv with current row
# Let reviewer write review.json
`

### Common process bugs to avoid

| Past bug | Fix |
|---|---|
| Told reviewer "report only" | Always require review.json file write |
| Restaged without verify.log | Always re-capture verify.log on every restage |
| Bumped agent-NNNN with stale artifacts | Always re-run verify, re-diff, re-manifest |
| Forgot to delete prior `review.json` when iterating REWORK | Delete prior review.json before re-dispatching reviewer |
| `tests_total` = full-repo suite, not what Verify ran | Count ONLY the tests the `Verify:` command executed |
| Known-failing tests left unexplained | Set `tests_known_failures` + a `tests_note` |
| `verify_command` with `cd workspace/<task>` (external-repo) | Use a BARE command -- the host runs verify INSIDE the worktree (cwd = repo_root already); a `cd workspace/<task>` fails "No such file or directory" and auto-rejects at tier 1-2 |
| Self-authored review.json (reviewer "orchestrator"/"orchestrator-inline") to skip reviewer dispatch, even for trivial or batch-driven multi-gen tasks | review.json MUST be written by a DISPATCHED reviewer subagent EVERY generation; driving many gens via a script does NOT exempt you. tier-7 static critic + reward-hack tripwire still run, but the semantic 6-check review is skipped when you self-author -- a real integrity gap (seqwork-ladder gen-0108..0122) |
| Hand-writing a lesson inbox file in YAML-frontmatter style | The appender REQUIRES first line "## [YYYY-MM-DD] Title" + headers **Context:** **Lesson:** **Why:** **How to apply:** **Source:** + trailing "---", <=4000 bytes; malformed drafts are quarantined to lessons-rejected/ and never reach LESSONS.md. Dispatch the archivist (reflexion-lessons skill) or match that schema exactly (seqwork gen-0122 lesson was lost this way) |
| Self-stopped with STOPPED_PLATEAU when the current engine merely found no gain, instead of escalating (hpfold gen-0177) | Local-no-improvement is a REJECT that MUST feed CONSECUTIVE_REJECTS -> PIVOT(2) -> meta-improver(3). Only STOP_PLATEAU after meta-improver double-rejects. "Needs a new engine" is the meta-improver's job, NOT a reason to hand back to the operator |

### Manifest test-count discipline — host tier-1-2 rejects on count drift

The host re-runs your exact `Verify:` command and parses `verify.log` for `N passed / M failed`, then checks `manifest.tests_passed`/`tests_total` against those numbers; **drift > 5 → auto-reject at tier 1-2**, even when the diff is perfect. Two real rejections (gen-68 breadth-gate, rejected TWICE):

- `manifest tests_total=103 but verify.log shows 15 ... (drift 88 > threshold 5)` — the manifest reported the **full repo suite (103)** while `Verify:` ran only the 15 targeted tests. Rule: `tests_passed`/`tests_total` count ONLY the tests the `Verify:` command actually executed in *this run's* `verify.log`, never the whole-repo `pytest` count.
- `tests_known_failures=4 requires manifest.tests_note` — if `tests_total - tests_passed > 0`, set `tests_known_failures` to that count AND add a `tests_note` explaining each pre-existing baseline failure, or host rejects.

Before every stage cross-check: `grep -E 'passed|failed' <staged>/verify.log` and make the manifest integers match that line exactly.
