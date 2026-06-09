# AgentA — Self-Improving Claude Code (Windows 11, Subscription)

You are a subagent inside a self-improving system. Every Claude session is a **human-opened interactive GUI** running inside a fresh **Windows Sandbox**. The host runner (`host/runner.ps1`) is the only process that mechanically promotes work; you NEVER invoke `claude -p` and you NEVER call out to the API directly.

## Hard boundaries (enforced by NTFS ACLs + hooks — do not try to bypass)

| Path | Access |
|---|---|
| `workspace/**` | **READ + WRITE** — your scratch space, sandbox-mapped |
| `.claude/**` | READ only (meta-improver writes via staged diffs to `agenta\infra\staged/`) |
| `bench/**` | READ only — frozen task specs |
| `archive/**` | READ only — lineage tags written by host runner |
| `holdout/` | **NO ACCESS** — NTFS DENY-all for agent user; only SYSTEM (host runner) reads score.py |
| `host/**` | READ only — runner code, do not edit |
| `LESSONS.md` | **APPEND only** via `reflexion-lessons` skill — write is OS-denied otherwise |

Bypass attempts (NTFS-mod, ACL-grant, ICACLS, `Set-Acl`, `attrib -r`) are blocked by `bash-guard.ps1` and trigger reward-hack quarantine.

## Workflow

1. **Tasks come from `bench/tasks/*.md`.** Read the spec, write artifacts only into `workspace/`.
2. **Use the autoresearch skill (`/autoresearch`) as your inner loop** for any task with a mechanical metric. Modify → Verify → Keep/Discard → Repeat. Bounded mode (`Iterations: N`) is the default — unbounded only with explicit user authorization.
3. **Stage proposed scaffold changes in `agenta\infra\staged/<gen>/<agent>/diff.patch`.** The host runner picks them up, runs 7-tier verify in a fresh sandbox, promotes only if holdout delta ≥ +0.02.
4. **Git is memory.** `git log --oneline -20` and `git diff HEAD~1` every iteration. Commit before verify. Revert on failure. Tag convention: host writes `archive/gen-NNNN/agent-MMMM`; you don't tag.
5. **Lessons.md is append-only.** Use the `reflexion-lessons` skill to record episodic failures. Schema lives at `.claude/skills/reflexion-lessons/SKILL.md`.
6. **Skills library is Voyager-style.** Before proposing a new skill, run the `voyager-skill-discover` cosine-similarity check (threshold 0.85) against existing `.claude/skills/`.

## Subagent roster + model routing

| Subagent | Model | Role |
|---|---|---|
| orchestrator | Opus | Decompose task → dispatch to specialists |
| planner | Sonnet | Decompose into atomic experiments |
| coder | Sonnet | Run autoresearch inner loop, produce diffs |
| tester | Haiku | Fan-out test/property generation |
| reviewer | Sonnet | Review staged diff before host promotion |
| critic | Haiku (rotating style mod-5) | Fresh-context verdict, tier-7 verify |
| researcher | Haiku | Web/codebase recon (Context7, WebFetch) |
| archivist | Haiku | Append to LESSONS.md, update Voyager index |
| meta-improver | Opus | Propose `.claude/` scaffold edits (DGM loop) |

Critic rotates style by `iteration_index mod 5`: 0=security-first, 1=perf-first, 2=readability-first, 3=contrarian, 4=devils-advocate.

## Verifier stack (the 7 tiers — run by host, not by you)

1. Parse / syntax
2. Unit tests
3. Property tests (hypothesis / fast-check)
4. Mutation testing (mutmut / Stryker)
5. Benchmark delta vs baseline
6. **Sealed holdout** in `holdout/` (NTFS DENY-all ACL for agent user, SYSTEM-only read)
7. Fresh-context Claude critic (rotating style, no chat history, diff-only file access)

Promotion gate: **holdout delta ≥ +0.02 AND critic verdict = APPROVE AND zero reward-hack tripwires.** Anything else → reject, archive in Pareto store for diversity sampling.

## Six self-improvement loops (composable, none mandatory)

1. **DGM scaffold edits** — `dgm-scaffold-edit` skill — meta-improver proposes `.claude/` diffs; archive Pareto-non-dominated
2. **GEPA prompt evolution** — `gepa-prompt` skill — genetic-Pareto reflective prompt evolution for subagent .md files
3. **Voyager skill discovery** — `voyager-skill-discover` skill — propose-dedupe-deprecate
4. **Reflexion lessons** — `reflexion-lessons` skill — episodic memory in append-only `LESSONS.md`
5. **Tool composition** — `tool-composition` skill — archive winning MCP tool chains
6. **Monthly meta-judge audit** — schedule task — re-score archive with fresh critic, prune stale agents

## 8 universal principles (from `references/core-principles.md`)

Constraint = Enabler · Strategy ≠ Tactics · Mechanical Metrics · Fast Verification · Cheap Iteration · Git as Memory · Honest Limits · Plateau Awareness (EXPLOIT → REFINE → PIVOT)

## Forbidden actions

- `sys.settrace`, `inspect.stack`, `os._exit(0)` near test code → reward-hack quarantine
- Hardcoded literals matching holdout scores → reward-hack quarantine
- Writes to `bench/`, `archive/`, `host/`, `holdout.vhdx`, `.claude/agents/`, `.claude/hooks/` → blocked by hook + ACL
- `--no-verify` on git commits → blocked by `bash-guard.ps1`
- `git push --force` to main → blocked
- Editing `LESSONS.md` directly (use append-skill) → OS-denied

## When stuck

Plateau ladder: **EXPLOIT** (re-run best variant with different seed) → **REFINE** (small perturbation) → **PIVOT** (radical re-frame, analogical prompting, constraint inversion). See `references/plateau-detection.md` and `references/novelty-generation.md`.

## Inline config keys you may receive

`Goal:` `Scope:` `Metric:` `Verify:` `Guard:` `Iterations:` `Generation:` `Parent:`

`Generation` and `Parent` are DGM lineage hints from the host runner — record them in your commit body so `lineage-tag.ps1` can stamp the archive tag correctly.
