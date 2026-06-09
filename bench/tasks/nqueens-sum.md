# nqueens-sum: N-Queens enumeration N=8..14 -> sub-second

## Goal
Rewrite `workspace/nqueens-sum/solver.py` to count solutions for the N-Queens problem at every N in 8..14 as fast as possible. Output is 7 per-N lines + a SUM line. Counts FROZEN per OEIS A000170 — cannot be faked, must be computed.

Baseline ~38s pure-Python recursion. Target <= 5.0s (bitmask + iterative). Stretch <= 1.0s (bitmask + symmetry). Meta-tier <= 0.1s (C extension).

## Scope
- `workspace/nqueens-sum/solver.py`  (MUTABLE)
- `workspace/nqueens-sum/check.py`  (READ ONLY — frozen verifier, oracle-gaming trip)
- `workspace/nqueens-sum/tests/test_correctness.py`  (READ ONLY — OEIS-grounded sanity gate)
- `workspace/nqueens-sum/README.md`  (READ ONLY — spec)

## Metric
Wall-clock seconds for `python solver.py`. Parsed from last line of `check.py` output as `METRIC=<seconds>`. Target <= 5.0.

## Verify
```bash
cd workspace/nqueens-sum && python -m pytest tests/ -q && python check.py
```
13 sanity tests on N=0..10 must pass + count for every N in 8..14 must match OEIS + SUM must equal 457356. Last line `METRIC=<seconds>` is the contract value re-measured by the host runner.

## Guard
```bash
cd workspace/nqueens-sum && python -m pytest tests/ -q
```
All 13 tests must pass every iteration. A failing test rolls the iteration back.

## Budget
- Iterations per gen: 15
- Generations per /orchestrate call: 20
- Wall-clock per gen: 60 min

## Specialist chain
researcher -> planner -> coder -> reviewer -> archivist

## Plateau ladder (hint for planner)

| Gen mode | Direction | Effect |
|---|---|---|
| EXPLOIT | bytearray cols + simple set->frozenset | ~1.5x |
| EXPLOIT | bitmask cols/diag1/diag2 as 3 ints, no set | ~5x |
| EXPLOIT | drop closure / nonlocal, inline place() | ~1.5x |
| REFINE | iterative explicit stack | ~3x |
| REFINE | left-right symmetry — only first column 0..ceil(N/2)-1, double count (subtract odd-N middle) | ~1.8x |
| REFINE | order-by-degree row pick, dynamic pruning | ~1.3x |
| PIVOT | precompute next-valid-bitmask per row | ~2x |
| PIVOT | numpy broadcast (limited gain, integer ops dominate) | ~1.5x |
| META | C extension via ctypes against in-tree solver.c/.pyd | ~30-50x |

If gens 1-4 plateau ~5s on bitmask, planner should escalate to symmetry-halving. If 5-8 plateau ~1s on Python-only, planner should signal `agenta/sentinels/<task>-no-direction.md` and orchestrator dispatches meta-improver for C-extension scaffolding.

## Anti-patterns (auto-quarantine)

- Hardcoding the 7 expected counts as literals near output → hack-detector trip
- Lookup table embedded in solver.py for N=8..14 results → BORDERLINE; reviewer checks function body has genuine enumeration
- Caching results to a file or DLL across runs → cold-run replay still timed
- Compiling DLL inside main() (replay-drift trap, like gen-0001/agent-0001 prime-sieve) → reviewer rejects, replay-drift sweep would catch
- Modifying check.py to relax timing or accept wrong counts → oracle gaming REJECT
- Modifying tests/test_correctness.py to skip cases → coverage erosion REJECT
- Math formula evaluation that hardcodes A000170 entries as DATA → reviewer rejects if no genuine search

## Baseline (informational)

- `python check.py` at HEAD: PASS sum=457356, time ~34.5s
- Baseline commit: `d59bae65f6bd77d60c8eae5d800d289011c151e5`
- All 13 correctness tests pass

## Nested-repo notes

Inner git repo at `workspace/nqueens-sum/`. Manifest MUST set `repo_root: workspace/nqueens-sum`. Host runner runs `git -C workspace/nqueens-sum worktree add --detach <baseline>`. Tier 5/6 skipped (external-repo). Tier 0 (review-gate, NEW), 1-4, and 7 run.

## Why this task

- Multi-size verification = much harder to fake (7 counts + sum must match)
- Plateau ladder forces algorithmic learning (bitmask -> symmetry -> C), not just constant-factor
- Python ceiling pushes loop into meta-improver / C-extension path
- 13 sanity tests on N=0..10 catch off-by-one bugs in fast-but-broken variants
- Baseline ~34.5s lets you feel speedups while still iterating in <10min/gen at baseline
- Replay-drift hardening exercised: DLL-compile-at-import patterns will fail review-gate

## Review-gate (NEW)

Host now requires `agenta\infra\staged/<gen>/<agent>/review.json` with `verdict=APPROVE` within 10min of staging. Reviewer subagent's 6-check audit blocks promotion. No more race between FSW debounce (3s) and reviewer turnaround (~2min). Earlier gen-0001 race incident is fixed.
