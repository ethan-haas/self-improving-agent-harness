---
name: gepa-prompt
description: Genetic-Pareto reflective prompt evolution. Evolves subagent prompts (.claude/agents/*.md) and skill SKILL.md files via reflect-on-rollout → mutate → A/B verify. 35× fewer rollouts than GRPO. Use only via meta-improver, only for prompt-rewrite mutation operator.
version: 0.1.0
---

# GEPA Prompt Evolution

Reference: Genetic-Pareto reflective prompt optimization (Anthropic / academic, 2025). Reported +12% on AIME, +10pp on AIME-mini with 10× cost reduction vs GRPO.

## When to use

Only invoked by `meta-improver` for the `prompt-rewrite` mutation operator from `dgm-scaffold-edit`. NOT a standalone command.

## Workflow

1. Read the target prompt file (e.g., `.claude/agents/coder.md`)
2. Read the last 5 archived rollouts that used this subagent — find which iterations failed and why (from `archive/gen-*/scores.json` + linked outcomes)
3. **Reflect:** identify ONE failure pattern. Phrase as a missing-instruction: "the prompt does not currently tell the agent to X, which caused failure Y."
4. **Mutate:** generate 3 candidate rewrites:
   - Conservative: add the missing instruction as a new bullet
   - Restructure: reorganize an existing section to surface the rule earlier
   - Constraint-inversion: state the OPPOSITE rule and see if reframing helps
5. **Pareto fitness:** each candidate's fitness vector = (predicted holdout improvement, brevity Δ, alignment with LESSONS.md)
6. Select the Pareto-non-dominated candidate (or sample one if multiple)
7. Stage as scaffold-edit per `dgm-scaffold-edit` workflow

## Rules

- **One prompt per proposal.** Don't co-edit multiple agents in a single GEPA pass — attribution becomes impossible.
- **Don't lengthen.** GEPA's value comes from finding *more effective* instructions, not more text. Cap line delta at ±20%.
- **Honor LESSONS.md.** If a rule was added because of a past incident, never delete it — only refine.
- **No metric-leakage.** Never write a prompt that tells the agent the holdout target value. The agent should not know what score it's chasing on holdout.

## Output

Standard scaffold-edit staged diff. The `manifest.json#mutation_operator = "prompt-rewrite"` and `manifest.json#gepa_reflection = "<one-paragraph failure pattern identified>"`.
