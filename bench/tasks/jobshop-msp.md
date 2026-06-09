# jobshop-msp: Job-Shop Scheduling makespan minimization (hardest long-horizon)

## Goal
Minimize SUM of makespans across 5 fixed 10x10 JSP instances. Baseline round-robin ~5409. Target <=4300 (local search). Stretch <=3900 (tabu). Far <=3600 (literature/shifting-bottleneck).

## Scope
- `workspace/jobshop-msp/solver.py`  (MUTABLE — only solve function)
- `workspace/jobshop-msp/check.py`  (READ ONLY — frozen verifier)
- `workspace/jobshop-msp/corpus.py`  (READ ONLY — frozen instance generator)
- `workspace/jobshop-msp/tests/test_correctness.py`  (READ ONLY — validity gate)
- `workspace/jobshop-msp/README.md`  (READ ONLY)

## Metric
SUM of makespans across 5 instances. Parsed from last line `METRIC=<value>` of check.py. Lower is better. Target <=4300.

## Verify
```bash
cd workspace/jobshop-msp && python -m pytest tests/ -q && python check.py
```

## Guard
```bash
cd workspace/jobshop-msp && python -m pytest tests/ -q
```
8 sanity tests must pass each iteration. Operation sequence must be valid (each job id exactly n_machines times); makespan is computed, cannot be faked.

## Budget per /orchestrate call
- Iterations per gen: 10
- Generations per call: 25 (long-horizon)
- Wall-clock per gen: 90 min

## Specialist chain
researcher → planner → coder → reviewer → archivist

## Plateau ladder (planner hint)

| Mode | Direction | Approx SUM |
|---|---|---|
| EXPLOIT | Dispatch rules (SPT/LPT/MWKR/MOR), best-of-several | ~5000 |
| REFINE | Giffler-Thompson active schedule generation | ~4600 |
| REFINE | Swap/insert local search on operation sequence | ~4300 |
| PIVOT | Critical-path block neighborhood (N1/N5 moves, van Laarhoven) | ~4000 |
| PIVOT | Tabu search (Nowicki-Smutnicki TSAB) | ~3900 |
| PIVOT | Genetic algorithm (operation-based / job-order crossover) | ~3700 |
| META | Shifting-bottleneck heuristic (Adams-Balas-Zawack) | ~3600 |
| META | C-extension for makespan/neighborhood eval (10-50x iters) | ~3500 |

JSP is a NEW domain — TSP lessons do NOT transfer (disjunctive constraints, not tour edges). Planner must build a fresh experiment ledger. Expected 20-30 gens to literature tier. C-ext helps throughput but the NEIGHBORHOOD STRUCTURE (critical-path blocks) is the real lever.

## Heartbeat protocol (MANDATORY)

Coder writes `agenta/sentinels/jobshop-msp-heartbeat.json` each iter. Watchdog fires `jobshop-msp-stuck.md` if stale >15min. Long tabu/GA runs MUST emit heartbeats so they aren't flagged hung.

## Plateau-abort (per coder.md rule)

If 5 iters all DISCARD with improvement < noise floor (~30u for this metric scale), write `agenta/infra/outcomes/jobshop-msp-plateau.md` PLATEAU_NO_STAGE and stop. Orchestrator escalates to meta-improver after 3 consecutive plateau/reject.

## Anti-patterns (auto-quarantine)

- Hardcoding precomputed sequences per seed → reward hacking; reviewer 6-check
- Modifying check.py/corpus.py/tests/* → oracle gaming REJECT
- External solver (OR-Tools, Gurobi, lekin, OptaPlanner) → out of scope; must be in-tree
- Compile-on-import C extension → replay-drift; pre-build + commit binary via `git diff --binary --full-index`
- Caching results to disk across runs → cold-run timed
- Invalid sequences (wrong length / job multiplicities) → validity FAIL

## Replay-drift hardening

Pre-build any C extension externally. Commit binary via `git diff --binary --full-index`. Load via ctypes at module init with graceful Python fallback. Compile-inside-import = drift CRITICAL → quarantine (gen-0001 prime-sieve lesson).

## Baseline (informational)

- `python check.py` at HEAD: PASS, SUM=5409 (round-robin: per-seed 1051/900/1070/1147/1241)
- Baseline commit: `27102c24cf5f1fac63dd0c34b66d208dbf390da9`
- 8 sanity tests pass

## Nested-repo notes

Inner repo at `workspace/jobshop-msp/`. Manifest MUST set `repo_root: workspace/jobshop-msp`. Host runs `git -C workspace/jobshop-msp worktree add --detach <baseline>`. Tier 5/6 skipped (external-repo). Tier 0 (review-gate), 1-4, 7 apply.

## Why this is the hardest seeded task

- Deepest plateau ladder (8 tiers vs 5-6 for prior tasks)
- New domain forces fresh memory ledger (no TSP transfer)
- Genuine NP-hard with no closed-form optimum
- Neighborhood theory (critical-path blocks) is subtle — many wrong implementations regress
- 25-gen horizon, multi-session — exercises resume, meta-improver escalation, lessons compounding, replay-drift over long arc
- C-ext alone insufficient (like tsp-multi finding) — structural algorithm improvement required
