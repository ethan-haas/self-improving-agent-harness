---
name: dgm-scaffold-edit
description: Darwin Gödel Machine outer loop. Propose edits to .claude/ scaffold (agents, skills, settings) to lift holdout score. Parent selection ~ proportional to (score × 1/(1+children)). Archive Pareto-non-dominated, including rejects for diversity sampling. Use only via meta-improver subagent.
version: 0.1.0
---

# DGM Scaffold Edit

Outer evolutionary loop over the agent's own scaffolding. Each "agent" in the archive is a snapshot of `.claude/` content; each "generation" is one round of staged proposals against the current best.

## Inputs

Called from `meta-improver.md`. Required inline config:
- `Goal:` — usually "increase holdout score by ≥0.02"
- `Parent:` — `archive/gen-NNNN/agent-MMMM` (sampled per the rule below) or `baseline`
- `Generation:` — the generation index this proposal belongs to

## Parent selection

Probability of sampling `agent-MMMM` from `archive/gen-*` as parent:

```
P(parent = a) ∝ score(a) × 1 / (1 + num_children(a))
```

Computed across all NON-PARETO-DOMINATED agents in the archive. Including REJECTED candidates from `archive/rejected/` for diversity. Sampling without replacement within a generation to prevent monoculture.

## Mutation operators

Pick ONE per proposal (no mixing — keep attribution clean):

1. **Prompt rewrite** — edit a single subagent .md (one of `.claude/agents/<name>.md`). Edit ≤30 lines.
2. **Add skill** — propose a new skill file under `.claude/skills/<new-name>/SKILL.md`. Must pass voyager-skill-discover cosine-dedupe.
3. **Skill refinement** — edit an existing skill's SKILL.md or one reference file.
4. **Settings tweak** — adjust permissions allow/deny or MCP server config in `.claude/settings.json`. **Note:** hooks paths are read-only — propose-only, no auto-apply.
5. **Tool composition** — add a recipe to `tool-composition` skill.

## Workflow

1. Read archive: `Get-ChildItem archive\gen-*` and parse each `scores.json`
2. Compute Pareto frontier on `(holdout_delta, bench_delta, critic_approval_rate)`
3. Sample parent per the rule above
4. Read parent's `diff.patch` to understand context
5. Choose ONE mutation operator
6. Apply mutation in `agenta/infra/staged/<gen>/<agent>/`
7. **Mode-collapse check:** cosine similarity vs last 10 promoted diffs. If >0.85, regenerate with constraint-inversion (apply opposite intuition) or analogical prompting (port a pattern from a different domain)
8. Stage `manifest.json`:
```json
{
  "category": "scaffold-edit",
  "generation": <int>,
  "agent": <int>,
  "parent": "archive/gen-NNNN/agent-MMMM",
  "mutation_operator": "prompt-rewrite|add-skill|skill-refinement|settings-tweak|tool-composition",
  "expected_holdout_delta": <number>,
  "rationale": "<one paragraph>"
}
```
9. Stop. Host runner promotes if tier 1-7 pass.

## Pareto archive

Even REJECTED proposals are archived at `archive/rejected/<gen>/<agent>/` with their rejection reason. Diversity sampling reads from this pool too — past failures inform future direction.

## When to stop

After 40 generations OR when holdout plateau detected (Δ < 0.005 for 10 consecutive generations). Trigger monthly-meta-judge audit at that point.

## References

- Darwin Gödel Machine (Sakana AI, 2024): 20% → 50% improvement on SWE-bench over 2 weeks / ~$22K
- See `.claude/skills/autoresearch/references/core-principles.md` and `plateau-detection.md`
