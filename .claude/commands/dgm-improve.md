---
description: Drive a DGM scaffold-improvement cycle from main session. Identifies one weakness in .claude/ scaffold, proposes a mutation, stages it. Subscription ToS-safe.
argument-hint: "[--generation N] [--parent archive/gen-NNNN/agent-MMMM | baseline]"
---

You are now driving the DGM meta-improvement loop for the AgentA scaffold itself. Subagents in Claude Code GUI cannot spawn other subagents (the `Agent` tool is filtered out of subagent toolsets), so dispatch happens here in main context. Same architectural fix as `/orchestrate`.

## Difference from `/orchestrate`

Task /orchestrate edits **workspace/** task source. /dgm-improve edits **.claude/** scaffold. The host runner's tier 5 (bench delta) and tier 6 (holdout) verify task-level metrics, not scaffold-level. Scaffold edits don't promote via the normal pipeline because no task code changes — bench delta and holdout both stay at 0.

**Promotion model for scaffold edits:** by manual review + LESSONS.md commit. Stage the diff in `agenta\infra\staged/<gen>/<agent>/` with `manifest.json#category = "scaffold-edit"`. Host runner sees the category and skips tier 5/6, runs only tier 1-2 (parse + any tests under .claude/skills/) and tier 7 (static-critic + reward-hack tripwire). On pass: copy to archive AND append a Reflexion lesson via the `reflexion-lessons` skill so the change compounds into future-task context.

## Workflow

### Step 1: Read archive lineage
```bash
ls archive/                         # promoted gens
ls archive/rejected/                # rejected proposals (still inform diversity)
cat archive/gen-*/agent-*/scores.json | grep holdout_delta
```
Compute the Pareto frontier on (holdout_delta, recency). Pick a parent via DGM sampling rule: `P(parent) ∝ score × 1/(1 + num_children)`. For the first run with no scaffold history: `parent: baseline`.

### Step 2: Identify one weakness
Read recent runs' patterns. Look for:
- Subagent toolset gaps (e.g. an agent grant-listed for `Agent` but runtime drops it -- past /orchestrate bug)
- Workflow steps that never fire (archivist, planner, tester have been silent across 4 promotions)
- Stale rules in CLAUDE.md or skill SKILL.md vs current behavior
- Reward-hack patterns reaching production despite tripwires
- Tasks that take many iterations because a hint is missing

Pick ONE concrete gap. Don't blend multiple mutations into one proposal -- attribution becomes impossible.

### Step 3: Pick a mutation operator
- `prompt-rewrite` — edit a single `.claude/agents/<name>.md` (≤30 lines diff)
- `add-skill` — propose new `.claude/skills/<new-name>/SKILL.md` (must clear voyager-skill-discover cosine ≤0.85)
- `skill-refinement` — edit existing SKILL.md or one of its reference files
- `settings-tweak` — adjust `.claude/settings.json` (NOT hooks paths; hooks/ is ACL-DENY anyway)
- `slash-command-rewrite` — edit `.claude/commands/<name>.md`
- `tool-composition` — add a recipe under `.claude/skills/tool-composition/recipes/`

### Step 4: Mode-collapse check
Before writing the diff, scan the last 10 promoted scaffold edits and compute cosine similarity of your proposed change against them. If max similarity > 0.85, regenerate with constraint-inversion (state the opposite rule and see if it lands) or analogical prompting (port a pattern from a different agent / skill / domain).

For the very first scaffold edit (no priors), skip this gate.

### Step 5: Write the diff
Use the Edit / Write tools on the proposed file. The change must be staged through git diff:
```bash
BASELINE=$(git rev-parse HEAD)
# ... do the edit ...
git diff $BASELINE > agenta\infra\staged/<gen>/<agent>/diff.patch
echo $BASELINE > agenta\infra\staged/<gen>/<agent>/baseline.txt
```

### Step 6: Stage manifest
```json
{
  "task_id": "scaffold-edit",
  "category": "scaffold-edit",
  "generation": <N>,
  "agent": <M>,
  "parent": "<parent ref>",
  "baseline_commit": "<sha>",
  "mutation_operator": "<one of step 3>",
  "rationale": "<one paragraph: what gap, what change, why this leverage>",
  "specialist_chain": ["meta-improver"],
  "verify_command": "echo 'scaffold-edit: no task verify'",
  "metric_name": "scaffold_health_proxy",
  "metric_value": 1.0,
  "tests_passed": 0,
  "tests_total": 0,
  "verify_exit_code": 0,
  "iterations_run": 1
}
```

### Step 7: Append a Reflexion lesson
After the diff is staged, distill the change into a `LESSONS.md` entry via the `reflexion-lessons` skill helper:
```bash
cat > workspace/<task>/lesson.md <<EOF
## [<date>] <one-line title>

**Context:** scaffold-edit gen-<N>/agent-<M>
**Lesson:** <single sentence rule>
**Why:** <single sentence reason>
**How to apply:** <single sentence trigger>
**Source:** archive/gen-<N>/agent-<M>
EOF
powershell -ExecutionPolicy Bypass -NoProfile -File .claude/skills/reflexion-lessons/append.ps1 -EntryFile workspace/<task>/lesson.md
```
This compounds: future /orchestrate runs read LESSONS.md context and avoid re-discovering the same gaps.

### Step 8: Print one-line summary
```
scaffold gen-<N>/agent-<M>: <mutation_operator> on <target>, rationale="<short>", lesson appended
```

## When to invoke

- After coder plateau on a task (10+ non-improvements across iterations)
- Monthly: scheduled meta-judge audit re-scores archive, prunes stale agents
- When a runtime gap repeatedly forces manual main-session compensation (the trigger for the current scaffold being upgradeable)

## Hard rules

- **One mutation per attempt.** No bundled "fix several things" diffs.
- **No bypassing hooks or ACLs.** If your proposed change requires loosening a guard, that is a separate proposal -- submit independently with explicit security rationale.
- **No reward-hacking the meta-loop.** Don't propose edits that game tier-7 critic or hack-detector. The post-tool hook will quarantine.
- **Append, don't rewrite.** Never delete a rule from CLAUDE.md or a SKILL.md without explaining why the rule is now wrong. Past rules exist because of past incidents -- read LESSONS.md before editing any agent .md.
