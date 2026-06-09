# closest-pair-2d: minimum pairwise distance from O(N^2) to sub-second

## Goal
Find minimum Euclidean distance between any two distinct 2D points on a fixed 10,000-point set. Baseline naive O(N^2) pure Python ~150s. Target <=2.0s. Stretch <=0.5s (divide-and-conquer). Meta <=0.05s (C extension).

## Scope
- `workspace/closest-pair-2d/solver.py`  (MUTABLE — only closest_pair function)
- `workspace/closest-pair-2d/check.py`  (READ ONLY — frozen verifier)
- `workspace/closest-pair-2d/corpus.py`  (READ ONLY — frozen deterministic generator)
- `workspace/closest-pair-2d/tests/test_correctness.py`  (READ ONLY — 8 sanity tests)
- `workspace/closest-pair-2d/README.md`  (READ ONLY)

## Metric
Wall-clock seconds for closest_pair(points) on 10,000 uniform points. Parsed from last line `METRIC=<seconds>` of check.py. Target <=2.0.

## Verify
```bash
cd workspace/closest-pair-2d && python -m pytest tests/ -q && python check.py
```

## Guard
```bash
cd workspace/closest-pair-2d && python -m pytest tests/ -q
```
8 sanity tests must pass + result must match `0.847917882047` within 1e-9.

## Budget per /orchestrate call
- Iterations per gen: 10
- Generations per call: 12
- Wall-clock per gen: 45 min

## Specialist chain
researcher -> planner -> coder -> reviewer -> archivist

## Plateau ladder (planner hint)

| Mode | Direction | Expected |
|---|---|---|
| EXPLOIT | numpy broadcast O(N^2), chunked to avoid OOM | ~3s |
| EXPLOIT | numpy + early termination upper-bound | ~2s |
| REFINE | numpy float32 + axis-summed squared distances | ~1.5s |
| PIVOT | Divide-and-conquer O(N log N), sort by x, strip merge | ~0.5s |
| PIVOT | KD-tree built from numpy arrays | ~0.3s |
| META | C extension via ctypes; PRE-BUILT .dll/.so committed via `--binary --full-index` | ~0.05s |

If gens 1-2 plateau at ~3s with naive numpy, planner should escalate to D&C. If gens 5+ plateau at ~0.5s on pure Python+numpy, signal `agenta/sentinels/closest-pair-2d-no-direction.md` -> meta-improver for C-ext scaffolding.

## Heartbeat protocol (MANDATORY)

Coder writes `agenta/sentinels/closest-pair-2d-heartbeat.json` each iter. Watchdog fires stuck sentinel if stale >15min.

## Anti-patterns (auto-quarantine)

- Hardcoding `return 0.847917882047` -> reviewer rejects + post-tool hack-detector trips
- Modifying check.py/corpus.py/tests/* -> oracle gaming REJECT
- Third-party deps (scipy.spatial.cKDTree, sklearn.neighbors.KDTree) -> out of scope; reviewer REJECT (must be in-tree)
- Compile-on-import C extension -> replay-drift; reviewer REJECT
- Caching result to disk across runs -> cold-run timed

## Replay-drift hardening

Pre-build any C extension. Commit binary via `git diff --binary --full-index`. Load via ctypes at module init. Compile-inside-import = drift CRITICAL -> quarantine.

## Baseline (informational)

- `python check.py` at HEAD: PASS distance=0.847917882047, time ~150s (naive pure-Python O(N^2))
- Baseline commit: `9466a46a1de0635a18c0467f32509499f605500e`
- 8 sanity tests pass

## Nested-repo notes

Inner repo at `workspace/closest-pair-2d/`. Manifest MUST set `repo_root: workspace/closest-pair-2d`. Host runs `git -C workspace/closest-pair-2d worktree add --detach <baseline>`. Tier 5/6 skipped (external-repo). Tier 0 (review-gate), 1-4, 7 still apply.

## Why this task tests reorganized pipeline

| Component | Exercised |
|---|---|
| `workspace/<task>/` location | task lives here (post move-back from agenta/tasks) |
| `agenta/infra/staged/` | coder stages diff here |
| `agenta/sentinels/` | heartbeat + status land here |
| `agenta/infra/lessons-inbox/` | archivist writes here directly (no Bash bypass needed - allowlist updated) |
| path-guard agenta allow-list | coder Write to workspace/closest-pair-2d/solver.py succeeds directly |
| Review-gate (tier 0) | reviewer APPROVE required |
| Replay-Archive fixed parser | METRIC=<x> line correctly extracted |
| Heartbeat watchdog | live during multi-gen coder runs |
| Coder ABSOLUTE BAN | no scaffold edits, no update-config invocations |
| Orchestrator layout discipline | uses workspace/<task>/, agenta/infra/orchestrate-queue/, agenta/sentinels/ |
| Memory-aware planner | reads EXPERIMENTS_TRIED across gens |
| Plateau ladder | 6 distinct tiers (baseline -> numpy -> D&C -> KD-tree -> C) |
| Meta-improver path | Python ceiling ~0.3s forces C-extension scaffolding |
| Continuous outer-loop | multi-gen until target/plateau/sentinel/cap |
| Lessons compounding | each gen lesson informs next direction |
