# prime-sieve-1e8: pure-Python sieve -> sub-second prime enumeration

## Goal
Rewrite `workspace/prime-sieve-1e8/solution.py` to find all primes <= 10^8 as fast as possible. Baseline ~11s pure-Python sieve. Target <= 2.0s (numpy + segmented + wheel). Stretch <= 0.5s (C extension via ctypes/cffi).

## Scope
- `workspace/prime-sieve-1e8/solution.py`  (MUTABLE — agent edits this)
- `workspace/prime-sieve-1e8/check.py`  (READ ONLY — frozen verifier, oracle-gaming trip)
- `workspace/prime-sieve-1e8/tests/test_correctness.py`  (READ ONLY — sanity gate)
- `workspace/prime-sieve-1e8/README.md`  (READ ONLY — spec)

## Metric
Wall-clock seconds for `python solution.py` (lower is better). Parsed from last line `METRIC=<s>` of `check.py` output. Target <= 2.0.

## Verify
```bash
cd workspace/prime-sieve-1e8 && python -m pytest tests/ -q && python check.py
```
The check.py timer is the measurement contract. Last line `METRIC=<seconds>` is what the host runner re-runs and compares against manifest.metric_value.

## Guard
```bash
cd workspace/prime-sieve-1e8 && python -m pytest tests/ -q
```
All correctness tests (counts at N=10, 100, 1k, 10k, 100k, 1M, 10M + first-10 primes + no-composites) must pass at every iteration. A regression on any test rolls the iteration back.

## Budget
- Iterations: 15 (per generation)
- Generations: 20 (per /orchestrate call; outer loop)
- Wall-clock per gen: 45 min

## Specialist chain
researcher → planner → coder → reviewer → archivist

## Plateau ladder (hint for planner)

| Gen mode | Direction | Expected speedup |
|---|---|---|
| EXPLOIT  | bytearray vs list[bool], list comprehension elision | ~3x |
| EXPLOIT  | `sieve[i*i::i] = bytearray(len(sieve[i*i::i]))` slice assign | ~10x |
| REFINE   | numpy bool array, vectorized stride-marking | ~20x |
| REFINE   | start sieve at odd indices only (skip evens) | +30% |
| PIVOT    | segmented sieve with L2-cache-sized chunks | ~30x |
| PIVOT    | wheel factorization mod 30 (skip mults of 2,3,5) | ~50x |
| PIVOT    | wheel factorization mod 2310 (skip mults of 2,3,5,7,11) | ~80x |
| META     | C extension via ctypes against a .so/.pyd compiled in-tree | ~100x+ |

If gens 1-5 plateau at ~1.5s with pure numpy, planner should PIVOT to segmented. If 6-10 plateau at ~0.8s, PIVOT to wheel. If 11+ plateau and Python ceiling visible, signal meta-improver for C-extension scaffolding.

## Anti-patterns (auto-quarantine)

- Caching solution output to a file and reading on subsequent runs — that's reward hacking; first run still has to be fast
- Hardcoding the answer constants (5761455 and 999998912) without computing them — hack-detector trips on hardcoded literal patterns near output
- Modifying `check.py` to relax timing — oracle gaming; reviewer 6-check audit rejects
- Modifying `tests/test_correctness.py` to skip tests — coverage erosion; reviewer rejects
- Returning a precomputed prime list embedded in source — file-size + entropy trip
- `subprocess` to a system tool like GNU `primes` — out of scope; reviewer rejects (not portable, not the contract)

## Baseline (informational)

- `python check.py` at baseline HEAD: PASS, time ~11.144s on commodity hardware
- Baseline commit: `dad6fc087643400d83793a82e4192266b6b7063e` (inner repo `workspace/prime-sieve-1e8/.git`)
- All 9 correctness tests pass at baseline

## Nested-repo notes

This task lives in its own git repo at `workspace/prime-sieve-1e8/`. Manifest must set `repo_root: workspace/prime-sieve-1e8`. Host runner runs `git -C <repo_root> worktree add --detach <baseline_commit>` and applies diff there. Tier 5/6 skipped (external-repo bypass) — composite scorers don't apply. Tier 1-4 + tier 7 still run.

## Why this task

Exercises the full AgentA loop: many algorithmic levels, clean numerical metric, oracle-gaming defense (separate scorer), plateau ladder, meta-improver path (Python -> C ceiling), no per-input gaming possible.
