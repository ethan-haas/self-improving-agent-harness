# tsp-multi: long-horizon TSP heuristic on 5 fixed instances

## Goal
Minimize SUM of tour lengths across 5 fixed 500-point TSP instances. Each instance gets a 5s wall-clock budget. Random-shuffle baseline ~1,324,000. Nearest-neighbor ~102,000. 2-opt ~85,000. LKH-style ~76,000. Concorde-class ~73,000.

This is a LONG-HORIZON task: no single algorithmic leap reaches optimum. 15-25 generations expected.

## Scope
- `workspace/tsp-multi/solver.py`  (MUTABLE — agent edits this)
- `workspace/tsp-multi/check.py`  (READ ONLY — frozen verifier)
- `workspace/tsp-multi/tests/test_correctness.py`  (READ ONLY — 8 sanity tests)
- `workspace/tsp-multi/README.md`  (READ ONLY)

## Metric
SUM of tour lengths across 5 instances (seeds 42, 123, 7, 99, 1337; 500 points each in [0,1000]^2). Parsed from `check.py` last line `METRIC=<value>`. **Lower is better.**

## Verify
```bash
cd workspace/tsp-multi && python -m pytest tests/ -q && python check.py
```

Per-instance time budget: 5.0s wall-clock. Subprocess timeout: 8.0s. Solutions exceeding budget by >1.5s are REJECTED.

## Guard
```bash
cd workspace/tsp-multi && python -m pytest tests/ -q
```
8 sanity tests must pass each iteration (permutation correctness, small-instance edge cases).

## Budget per /orchestrate call
- Iterations per gen: 10
- Generations per call: 20 (default outer-loop cap)
- Wall-clock per gen: 90 min

## Plateau ladder

| Mode | Direction | Approx SUM |
|---|---|---|
| EXPLOIT 1 | Nearest-neighbor from start 0 | ~105,000 |
| EXPLOIT 2 | NN from many starts, keep best | ~100,000 |
| REFINE 1 | 2-opt local search until convergence | ~85,000 |
| REFINE 2 | Or-opt (segment-shift) + 2-opt iteration | ~82,000 |
| REFINE 3 | Don't-look-bits + neighbor lists | ~80,000 (more iters in budget) |
| PIVOT 1 | 3-opt local search | ~80,000 |
| PIVOT 2 | Lin-Kernighan-style k-opt | ~76,000 |
| PIVOT 3 | Simulated annealing with adaptive temp | ~78,000 |
| PIVOT 4 | Christofides construction + local search | ~76,000 |
| META 1 | C extension for 2-opt inner loop (10-50x iters/s) | ~74,000 |
| META 2 | multiprocessing.Pool best-of-N restarts | ~74,000 |
| META 3 | Spatial index (kd-tree) for neighbor pruning | substantial |

Expected progression: gen 1 NN ~105k, gen 3 2-opt ~85k, gen 6 multi-heuristic ~80k, gen 12+ literature-tier 74-76k. Plateau after ~15 gens typical.

## Targets

| `/orchestrate --target` | Tier |
|---|---|
| (default) | First-pass NN beats baseline by 10x |
| `--target 90000` | Local-search level |
| `--target 80000` | Multi-heuristic level |
| `--target 75000` | Literature-competitive |
| `--target 73500` | Near-Concorde |

## Anti-patterns (auto-quarantine)

- Hardcoding pre-computed tours for any seed → reward hacking; reviewer 6-check audit REJECT
- Calling system binary (`concorde`, `lkh`) via subprocess → out of scope; REJECT
- Caching tour to file across runs → first cold run still timed; subsequent runs are reproducibility failures
- Modifying check.py constants or budget → oracle gaming REJECT
- Modifying tests/test_correctness.py to skip cases → coverage erosion REJECT
- Embedding LKH binary as binary blob in repo → out of scope; reviewer detects
- Detecting test instances by points fingerprint and returning memoized tours → reward hacking; reviewer pattern-checks
- Ignoring 5s+1.5s grace budget → check.py rejects automatically

## Replay-drift hardening (lesson from gen-0001 prime-sieve)

DO NOT compile C extensions inside `solver.py`'s import path. Pre-build any DLL/.so externally, commit binary via `git diff --binary --full-index`, load via ctypes at module init. Otherwise cold-sandbox replay shows compile-time inside timer = drift CRITICAL = quarantine via Replay-Archive sweep.

## Baseline (informational)

- `python check.py` at HEAD: PASS SUM=1,324,616.68, time ~25s
- Inner repo baseline commit: `be98548575c4a5eaa9a9308b2fc66fe95080020e`
- All 8 correctness tests pass at baseline

## Nested-repo notes

Inner repo at `workspace/tsp-multi/`. Manifest MUST set `repo_root: workspace/tsp-multi`. Host runner uses `git -C workspace/tsp-multi worktree add --detach <baseline>`. Tier 5/6 skipped (external-repo). Tier 0 (review-gate), 1-4, and 7 still apply.

## Why long-horizon vs single-shot

Unlike prime-sieve and nqueens-sum (where C extension yielded 100x+ in one step), TSP heuristics compose. Each layer (NN, 2-opt, Or-opt, LK, restarts) unlocks NEXT layer's gains. C extension doesn't help by itself — it just runs the SAME algorithm faster, which lets you do more iterations. Better algorithm beats faster bad algorithm. This tests:

1. **Memory-aware planner across many gens** — each plan must extend prior gen's work, not redo
2. **Plateau ladder traversal** — multiple distinct algorithmic levels
3. **Meta-improver path under genuine ceiling** — when local-search plateaus, only NEW algorithm class breaks through
4. **Lessons accumulation utility** — each gen's lesson informs next directional choice
5. **3-reject auto-escalation to meta-improver** — likely fires at ~78k plateau
6. **Replay-drift defense in long-running context** — many gens of binary commits

This task should require 15-25 gens to reach literature-tier. NOT solvable in 2 gens like prior tasks.
